// CodexMCPClient.swift
// Half B of bidirectional MCP (see project_mira_codex): a warm, persistent Codex.
// Instead of a cold `codex exec …` spawn per task, Mira runs `codex mcp-server` once
// (a stdio MCP server) and acts as its MCP CLIENT — sending tasks as `tools/call`
// against the server's `codex` tool, and threading `threadId` for session continuity
// ("now also do X"). Removes cold-start latency and enables multi-turn sessions.
//
// Verified protocol (2026-06-17, codex 0.140 `codex mcp-server`):
//   - stdio, newline-delimited JSON-RPC 2.0.
//   - serverInfo name="codex-mcp-server"; tools = `codex` (prompt, model, cwd, sandbox,
//     approval-policy, config, …) and `codex-reply` (conversationId/threadId, prompt).
//   - tools/call result: {content:[{type:text,text}], structuredContent:{threadId, content}}.
//   - progress streams as `codex/event` notifications with params.msg.type
//     (session_configured / agent_message / item_* / task_complete / mcp_startup_*).
//   - codex mcp-server auto-starts ITS configured MCP servers, including `mira` — so
//     MIRA_MCP_TOKEN must be in the env for Mira's own tools to be reachable from here
//     (full bidirectional loop). Without it: mcp_startup_update server=mira state=failed.
//
// Scope (v1): wired into the CODING lane (CodexService.run when transport=mcp), which is
// text-in/text-out and benefits from continuity. The computer-use lane stays on the
// proven exec transport (full HUD + on-screen overlay) until a live test confirms warm
// computer-use + HUD parity. `stepHandler` is provided so a HUD can be attached later.

import Foundation

@MainActor
final class CodexMCPClient: ObservableObject {
    static let shared = CodexMCPClient()
    private init() {}

    // MARK: - State

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var initialized = false
    private var nextId = 1000
    private var pending: [Int: CheckedContinuation<[String: Any], Never>] = [:]

    /// Conversation handle for continuity; set from the first run's structuredContent.
    private(set) var threadId: String?

    /// Optional live-progress sink (codex/event notifications, mapped to readable lines).
    /// A HUD can set this to mirror warm-server progress.
    var stepHandler: ((String) -> Void)?

    private var resolvedBin: String?

    // MARK: - Public API

    /// Start a fresh Codex session for `prompt`. Cold-starts the warm server on first use.
    @discardableResult
    func run(prompt: String, workdir: String? = nil, timeout: TimeInterval = 600) async -> CodexService.CodexResult {
        threadId = nil
        return await call(tool: "codex", arguments: codexArgs(prompt: prompt, workdir: workdir), timeout: timeout)
    }

    /// Continue the current session ("now also do X"). Falls back to a fresh run if there
    /// is no live thread yet.
    @discardableResult
    func continueSession(prompt: String, timeout: TimeInterval = 600) async -> CodexService.CodexResult {
        guard let tid = threadId else { return await run(prompt: prompt, timeout: timeout) }
        return await call(tool: "codex-reply",
                          arguments: ["threadId": tid, "conversationId": tid, "prompt": prompt],
                          timeout: timeout)
    }

    func shutdown() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        initialized = false
        pending.removeAll()
        readBuffer.removeAll()
        threadId = nil
    }

    var isWarm: Bool { process?.isRunning == true && initialized }

    // MARK: - tools/call

    private func codexArgs(prompt: String, workdir: String?) -> [String: Any] {
        let effort = EntitlementService.shared.plan.codexReasoningEffort
        var args: [String: Any] = [
            "prompt": prompt,
            // Match the exec bypass intent so Codex can use tools (incl. Mira's) without
            // elicitation stalls; Mira owns safety via its own gates.
            "approval-policy": "never",
            "sandbox": "danger-full-access",
            "config": ["model_reasoning_effort": effort]
        ]
        if let wd = workdir, !wd.isEmpty { args["cwd"] = wd }
        return args
    }

    private func call(tool: String, arguments: [String: Any], timeout: TimeInterval) async -> CodexService.CodexResult {
        guard await ensureStarted() else {
            return CodexService.CodexResult(success: false, output: "Codex warm server unavailable.", exitCode: 127)
        }
        let id = nextId; nextId += 1
        let req: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        guard send(req) else {
            return CodexService.CodexResult(success: false, output: "Failed to send to Codex warm server.", exitCode: 1)
        }

        // Await the matching response, racing a timeout watchdog.
        let response: [String: Any]? = await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { await self.awaitResponse(id: id) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let result = response?["result"] as? [String: Any] else {
            // Timed out or errored — resolve any dangling continuation and report.
            resolve(id: id, with: [:])
            let errMsg = (response?["error"] as? [String: Any])?["message"] as? String
            return CodexService.CodexResult(success: false,
                                            output: errMsg ?? "Codex warm task timed out.",
                                            exitCode: 1)
        }

        if let sc = result["structuredContent"] as? [String: Any],
           let tid = sc["threadId"] as? String { threadId = tid }

        let isError = result["isError"] as? Bool ?? false
        let text = ((result["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined(separator: "\n"))
            ?? ((result["structuredContent"] as? [String: Any])?["content"] as? String)
            ?? ""
        return CodexService.CodexResult(success: !isError && !text.isEmpty, output: text, exitCode: isError ? 1 : 0)
    }

    private func awaitResponse(id: Int) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            pending[id] = cont
        }
    }

    private func resolve(id: Int, with value: [String: Any]) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(returning: value) }
    }

    // MARK: - Lifecycle / handshake

    private func ensureStarted() async -> Bool {
        if isWarm { return true }
        shutdown()
        guard let bin = await resolveBin() else { return false }

        let proc = Process()
        proc.launchPath = "/bin/zsh"
        proc.arguments = ["-lc", "\(bin) mcp-server"]
        var env = ProcessInfo.processInfo.environment
        env[CodexBridgeConfig.tokenEnvVar] = MiraMCPServer.shared.token   // bidirectional loop
        proc.environment = env

        let inPipe = Pipe(); let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }
        do { try proc.run() } catch { return false }
        process = proc
        stdinHandle = inPipe.fileHandleForWriting

        // initialize handshake.
        let initId = nextId; nextId += 1
        _ = send(["jsonrpc": "2.0", "id": initId, "method": "initialize",
                  "params": ["protocolVersion": "2025-06-18",
                             "capabilities": [String: Any](),
                             "clientInfo": ["name": "mira", "version": "1.0"]]])
        let initResp = await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { await self.awaitResponse(id: initId) }
            group.addTask { try? await Task.sleep(nanoseconds: 15 * 1_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard initResp?["result"] != nil else { resolve(id: initId, with: [:]); shutdown(); return false }
        _ = send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
        return true
    }

    private func resolveBin() async -> String? {
        if let b = resolvedBin { return b }
        let out = await PythonSkillRunner.shared.shellRun("which codex 2>/dev/null", timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.hasPrefix("/") else { return nil }
        resolvedBin = "'" + out.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return resolvedBin
    }

    // MARK: - Stream ingest (newline-delimited JSON-RPC)

    private func ingest(_ chunk: Data) {
        readBuffer.append(chunk)
        guard let nl = "\n".data(using: .utf8)?.first else { return }
        while let idx = readBuffer.firstIndex(of: nl) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            handle(message: obj)
        }
    }

    private func handle(message: [String: Any]) {
        let hasId = message["id"] != nil
        let method = message["method"] as? String

        if let method, hasId {
            // Server -> client REQUEST (e.g. tool-call approval / elicitation). Mira owns
            // safety, so auto-approve so the warm session never stalls waiting on us.
            respondToServerRequest(id: message["id"], method: method, params: message["params"] as? [String: Any])
            return
        }
        if let method {
            // Notification — surface codex/event progress to an optional HUD sink.
            if method == "codex/event", let line = describeEvent(message["params"] as? [String: Any]) {
                stepHandler?(line)
            }
            return
        }
        // Response to one of our requests.
        if let idInt = message["id"] as? Int { resolve(id: idInt, with: message) }
    }

    /// Best-effort approval of server-initiated requests. Exact method names vary by Codex
    /// version; approve the ones we recognize and ack the rest with an empty result so the
    /// JSON-RPC call doesn't hang. (We requested approval-policy=never, so this is rarely hit.)
    private func respondToServerRequest(id: Any?, method: String, params: [String: Any]?) {
        var result: [String: Any] = [:]
        let m = method.lowercased()
        if m.contains("elicit") {
            result = ["action": "accept", "content": params?["defaults"] as? [String: Any] ?? [:]]
        } else if m.contains("approv") || m.contains("permission") || m.contains("confirm") {
            result = ["decision": "approved", "approved": true]
        }
        _ = send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func describeEvent(_ params: [String: Any]?) -> String? {
        guard let msg = params?["msg"] as? [String: Any], let type = msg["type"] as? String else { return nil }
        switch type {
        case "agent_message":   return (msg["message"] as? String).map { "💬 \($0)" }
        case "task_complete":   return "✅ done"
        case "mcp_tool_call", "item_started", "item_completed":
            if let item = msg["item"] as? [String: Any], let it = item["type"] as? String { return "• \(it)" }
            return nil
        default: return nil
        }
    }

    // MARK: - Send

    @discardableResult
    private func send(_ obj: [String: Any]) -> Bool {
        guard let h = stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        data.append(0x0A) // newline-delimited
        do { try h.write(contentsOf: data); return true } catch { return false }
    }
}
