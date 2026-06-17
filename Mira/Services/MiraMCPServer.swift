// MiraMCPServer.swift
// Half A of bidirectional MCP (see project_mira_codex): an in-process, loopback-only
// streamable-HTTP MCP server that exposes Mira's own tools (MiraToolService) to Codex.
// Codex registers this server via ~/.codex/config.toml (see CodexBridgeConfig) and can
// then call back into Mira — calendar, knowledge/memory, project context, and (per Tre's
// choice) all of MiraToolService — while Mira is driving it.
//
// Transport: MCP JSON-RPC 2.0 over a single `POST /mcp` endpoint. Non-streaming
// request/response is spec-legal and sufficient for these synchronous tools, so no SSE.
// Auth: a per-launch random bearer token (held in memory, never written to disk); the
// listener also binds to 127.0.0.1 only. The HTTP/NWListener plumbing mirrors WebhookServer.

import Foundation
import Network
import AppKit

@MainActor
final class MiraMCPServer: ObservableObject {
    static let shared = MiraMCPServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0

    /// Per-launch bearer token. Codex receives this via the MIRA_MCP_TOKEN env var
    /// injected at spawn time (see CodexComputerUseService / CodexService). If the app
    /// is launched with MIRA_MCP_TOKEN already set in its environment, that value is
    /// used (handy for testing / a stable session token); otherwise a fresh random
    /// token is generated and never written to disk.
    let token: String = ProcessInfo.processInfo.environment["MIRA_MCP_TOKEN"]
        ?? MiraMCPServer.makeToken()

    private var listener: NWListener?
    private let candidatePorts: [UInt16] = [8765, 8766, 8767, 8790]
    private var portIndex = 0

    /// Actuation tools that can affect the system beyond reading/knowledge. Exposed by
    /// default (Tre chose "everything"), but gated behind a confirmation prompt and a
    /// kill switch so they can never fire silently from a Codex MCP call.
    private static let dangerousTools: Set<String> = [
        "run_shell_command", "run_apple_script", "lock_screen",
        "quit_application", "spawn_agent", "run_coding_agent"
    ]

    /// Kill switch: when false, the dangerous tools are hidden from tools/list and
    /// refused on tools/call. Default on (Tre asked for the full surface).
    private var exposeActuation: Bool {
        UserDefaults.standard.object(forKey: "mira_mcp_expose_actuation") as? Bool ?? true
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        portIndex = 0
        bindNextCandidate()
    }

    private func bindNextCandidate() {
        guard portIndex < candidatePorts.count else {
            print("[MiraMCPServer] No free port among \(candidatePorts)")
            return
        }
        let p = candidatePorts[portIndex]
        do {
            let params = NWParameters.tcp
            // Bind to loopback only — the MCP surface must never be reachable off-box.
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                      port: NWEndpoint.Port(rawValue: p)!)
            let l = try NWListener(using: params)
            self.listener = l
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.port = p
                        print("[MiraMCPServer] listening on http://127.0.0.1:\(p)/mcp")
                        // Register with Codex now that we know the actual bound port.
                        CodexBridgeConfig.reconcile(port: p)
                    case .failed:
                        // Port likely in use — try the next candidate.
                        self.isRunning = false
                        self.listener?.cancel()
                        self.listener = nil
                        self.portIndex += 1
                        self.bindNextCandidate()
                    default:
                        break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(connection: conn) }
            }
            l.start(queue: .main)
        } catch {
            print("[MiraMCPServer] failed to create listener on \(p): \(error)")
            portIndex += 1
            bindNextCandidate()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    // MARK: - Connection handling (mirrors WebhookServer)

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readAll(connection: connection, accumulated: Data()) { [weak self] data in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                let response = await self.respond(rawRequest: raw)
                connection.send(content: response,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func readAll(connection: NWConnection, accumulated: Data,
                         completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isDone, error in
            if error != nil { completion(nil); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if isDone || self.hasFullRequest(buf) {
                completion(buf)
            } else {
                self.readAll(connection: connection, accumulated: buf, completion: completion)
            }
        }
    }

    private func hasFullRequest(_ data: Data) -> Bool {
        guard let sep = "\r\n\r\n".data(using: .utf8),
              let range = data.range(of: sep) else { return false }
        let headerPart = data[..<range.lowerBound]
        guard let headerStr = String(data: headerPart, encoding: .utf8) else { return false }
        if let clLine = headerStr.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(clLine.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
            return data.count >= range.upperBound + length
        }
        return true
    }

    // MARK: - HTTP → MCP JSON-RPC

    private func respond(rawRequest: String) async -> Data {
        let (headers, body) = splitRequest(rawRequest)

        // Auth: require the per-launch bearer token.
        let auth = headerValue(headers, name: "Authorization") ?? ""
        guard auth == "Bearer \(token)" else {
            return httpResponse(status: "401 Unauthorized", json: nil)
        }

        guard let bodyData = body.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = req["method"] as? String else {
            return httpResponse(status: "200 OK",
                                json: jsonRPCError(id: nil, code: -32700, message: "Parse error"))
        }

        let id = req["id"]   // absent for notifications

        // Notifications carry no id and expect no JSON-RPC response body.
        if id == nil || method.hasPrefix("notifications/") {
            return httpResponse(status: "202 Accepted", json: nil)
        }

        switch method {
        case "initialize":
            return httpResponse(status: "200 OK", json: jsonRPCResult(id: id, result: [
                "protocolVersion": (req["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "mira", "version": appVersion()]
            ]))

        case "ping":
            return httpResponse(status: "200 OK", json: jsonRPCResult(id: id, result: [:]))

        case "tools/list":
            return httpResponse(status: "200 OK", json: jsonRPCResult(id: id, result: [
                "tools": exposedTools()
            ]))

        case "tools/call":
            let params = req["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await callTool(name: name, arguments: arguments)
            return httpResponse(status: "200 OK", json: jsonRPCResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": isError
            ]))

        default:
            return httpResponse(status: "200 OK",
                                json: jsonRPCError(id: id, code: -32601,
                                                   message: "Method not found: \(method)"))
        }
    }

    // MARK: - Tool surface

    /// Convert MiraToolService.definitions (OpenAI function shape) → MCP tool shape.
    private func exposedTools() -> [[String: Any]] {
        MiraToolService.definitions.compactMap { def in
            guard let name = def["name"] as? String else { return nil }
            if !exposeActuation && Self.dangerousTools.contains(name) { return nil }
            return [
                "name": name,
                "description": def["description"] as? String ?? "",
                "inputSchema": def["parameters"] as? [String: Any]
                    ?? ["type": "object", "properties": [String: Any]()]
            ]
        }
    }

    /// Execute a tool call, guarding dangerous tools behind a confirmation prompt.
    private func callTool(name: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
        guard MiraToolService.definitions.contains(where: { ($0["name"] as? String) == name }) else {
            return ("Unknown tool: \(name)", true)
        }
        if Self.dangerousTools.contains(name) {
            if !exposeActuation {
                return ("Refused: actuation tools are disabled (mira_mcp_expose_actuation).", true)
            }
            if !confirmDangerous(name: name, arguments: arguments) {
                return ("Refused by user: \(name) was not approved.", true)
            }
        }
        let argsJSON = (try? JSONSerialization.data(withJSONObject: arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let result = await MiraToolService.execute(name: name, argsJSON: argsJSON)
        return (result, false)
    }

    /// Native modal gate so a Codex MCP call can never run a dangerous tool silently
    /// (Codex bypasses RouterService.detectDangerousCommand, so we re-gate here).
    private func confirmDangerous(name: String, arguments: [String: Any]) -> Bool {
        let detail: String
        if let d = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8), s != "{}" {
            detail = "\n\n\(s)"
        } else {
            detail = ""
        }
        let alert = NSAlert()
        alert.messageText = "Codex wants to run “\(name)”"
        alert.informativeText = "Mira is being driven by Codex, which requested a system action.\(detail)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - JSON-RPC / HTTP helpers

    private func jsonRPCResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func httpResponse(status: String, json: [String: Any]?) -> Data {
        let bodyData: Data
        if let json, let d = try? JSONSerialization.data(withJSONObject: json) {
            bodyData = d
        } else {
            bodyData = Data()
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = head.data(using: .utf8) ?? Data()
        out.append(bodyData)
        return out
    }

    private func splitRequest(_ raw: String) -> (headers: String, body: String) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        return (parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func headerValue(_ headers: String, name: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 && kv[0].lowercased() == name.lowercased() {
                return kv.dropFirst().joined(separator: ": ")
            }
        }
        return nil
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
