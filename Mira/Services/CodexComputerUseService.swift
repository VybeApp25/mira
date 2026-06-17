import Foundation

// MARK: - Codex computer-use (desktop-control engine)
//
// Drives the Mac through OpenAI Codex's computer-use plugin — an alternative to
// the Claude ComputerUseOrchestrator vision loop (see project_mira_codex /
// project_mira_autonomy_direction). Runs `codex exec "<task>" --json` and parses
// the JSONL event stream LIVE so progress can drive a HUD, with no fixed timeout
// (real desktop tasks run long) and a Stop kill-switch.
//
// Verified event shape (2026-06-16):
//   {"type":"thread.started", ...} / {"type":"turn.started"}
//   {"type":"item.started"|"item.completed","item":{
//        "type":"mcp_tool_call","server":"computer-use","tool":"…","status":"…"}}
//   {"type":"item.completed","item":{"type":"agent_message","text":"…"}}
//   {"type":"turn.completed","usage":{...}}
// Codex enforces its OWN app safety allow/deny (e.g. refuses Terminal); Mira
// does not control that guardrail.

@MainActor
final class CodexComputerUseService: ObservableObject {
    static let shared = CodexComputerUseService()
    private init() {}

    struct Step: Identifiable {
        let id = UUID()
        let kind: Kind
        let text: String
        enum Kind { case thinking, tool, toolResult, message, system, refusal }
    }

    /// How the last run ended — lets the auto engine router decide whether to
    /// transparently fail over to the Claude engine. `.stopped` (user hit Stop)
    /// and `.succeeded` must NOT trigger failover.
    enum Outcome { case idle, succeeded, refused, failed, stopped }

    @Published private(set) var isRunning = false
    @Published private(set) var steps: [Step] = []
    @Published private(set) var result = ""
    @Published private(set) var lastOutcome: Outcome = .idle

    private var process: Process?
    private var stopRequested = false

    // Tool-call tallies for outcome classification: if Codex attempted actions
    // but none succeeded, the task didn't actually happen — even if it ends with
    // a polite "I couldn't…" message (which would otherwise look like success).
    private var toolSuccesses = 0
    private var toolFailures  = 0

    /// Run a desktop-control task through Codex computer-use. Streams steps as it
    /// goes; returns the agent's final message. Blocks until the task finishes or
    /// stop() is called.
    @discardableResult
    func run(task: String) async -> String {
        guard !isRunning else { return "A Codex task is already running." }
        isRunning = true
        stopRequested = false
        steps = []
        result = ""
        lastOutcome = .idle
        toolSuccesses = 0
        toolFailures  = 0
        CodexLiveOverlay.shared.begin()   // live on-screen ring/arrow layer
        append(.system, "Starting Codex computer-use…")

        // Run through a login shell so the nvm-installed `codex` is on PATH.
        // --json streams events; --skip-git-repo-check because desktop control
        // isn't a coding task and needs no repo. Reasoning effort scales with the
        // user's tier — the main cost lever on this (token-heavy) path.
        let effort = EntitlementService.shared.plan.codexReasoningEffort
        let escaped = task.replacingOccurrences(of: "'", with: "'\\''")
        // Codex gates MCP/computer-use tool calls behind its own approval+sandbox; in
        // non-interactive `exec` only the full bypass lets them through (verified
        // 2026-06-17). Mira owns safety via its own gates (RouterService danger-confirm
        // + MiraMCPServer's dangerous-tool prompt), so default to bypassing Codex's.
        // Kill switch: mira_codex_bypass_sandbox.
        let bypass = (UserDefaults.standard.object(forKey: "mira_codex_bypass_sandbox") as? Bool ?? true)
            ? " --dangerously-bypass-approvals-and-sandbox" : ""
        let command = "codex exec '\(escaped)' --json --skip-git-repo-check\(bypass) -c model_reasoning_effort=\(effort)"

        let proc = Process()
        proc.launchPath = "/bin/zsh"
        proc.arguments  = ["-lc", command]
        // Bidirectional MCP: let Codex authenticate back into Mira's MCP server.
        var env = ProcessInfo.processInfo.environment
        env[CodexBridgeConfig.tokenEnvVar] = MiraMCPServer.shared.token
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        process = proc

        do {
            try proc.run()
        } catch {
            append(.system, "Failed to launch Codex: \(error.localizedDescription)")
            finish()
            return result
        }

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if stopRequested { break }
                handle(line: line)
            }
        } catch {
            append(.system, "Stream error: \(error.localizedDescription)")
        }

        proc.waitUntilExit()
        finish()
        return result
    }

    func stop() {
        stopRequested = true
        process?.terminate()
        append(.system, "Stopped by user.")
    }

    // MARK: - Event parsing

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }   // non-JSON log lines (stderr) are ignored

        switch type {
        case "item.started", "item.completed":
            guard let item = event["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return }
            let done = (type == "item.completed")
            switch itemType {
            case "mcp_tool_call":
                let tool   = item["tool"] as? String ?? "?"
                let status = item["status"] as? String ?? ""
                if done {
                    let failed = status == "failed"
                    if failed { toolFailures += 1 } else { toolSuccesses += 1 }
                    let detail = failed ? toolResultText(item) : ""
                    if failed, isRefusal(detail) {
                        // Codex's OWN app-safety guardrail blocked this app — surface
                        // it as a deliberate refusal, not a Mira malfunction.
                        append(.refusal, "Codex declined to control \(appName(item, fallback: tool)) for safety.")
                    } else {
                        append(.toolResult, "\(failed ? "⚠️" : "✓") \(tool) \(failed ? "— \(detail)" : "")"
                            .trimmingCharacters(in: .whitespaces))
                    }
                } else {
                    append(.tool, "→ \(tool)\(argsSuffix(item))")
                    // Draw a live ring/arrow where this action lands, if it carries coords.
                    if let p = actionPoint(item) {
                        CodexLiveOverlay.shared.mark(rawX: p.x, rawY: p.y)
                    }
                }
            case "agent_message":
                if done, let text = item["text"] as? String, !text.isEmpty {
                    append(isRefusal(text) ? .refusal : .message, text)
                    result = text   // last agent message is the outcome
                }
            default:
                break
            }
        case "turn.completed":
            if let usage = event["usage"] as? [String: Any],
               let inTok = usage["input_tokens"] as? Int,
               let outTok = usage["output_tokens"] as? Int {
                append(.system, "Turn complete · \(inTok) in / \(outTok) out tokens")
            }
        default:
            break   // thread.started / turn.started — no UI line needed
        }
    }

    private func argsSuffix(_ item: [String: Any]) -> String {
        guard let args = argumentsDict(item), !args.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: args),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return " \(s.prefix(80))"
    }

    /// Codex sends tool `arguments` either as a JSON object or a JSON-encoded
    /// string — normalize both to a dictionary.
    private func argumentsDict(_ item: [String: Any]) -> [String: Any]? {
        if let dict = item["arguments"] as? [String: Any] { return dict }
        if let str = item["arguments"] as? String,
           let data = str.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    /// Best-effort extraction of the on-screen point an action targets, tolerant
    /// of the coordinate shapes the computer-use plugin might use (`x`/`y`,
    /// `coordinate` as [x,y] or {x,y}, or a drag's `to`). Returns raw plugin
    /// coords; CodexLiveOverlay maps them to screen points. nil for non-spatial
    /// tools (screenshot/type/key/get_app_state).
    private func actionPoint(_ item: [String: Any]) -> CGPoint? {
        guard let a = argumentsDict(item) else { return nil }
        if let x = num(a["x"]), let y = num(a["y"]) { return CGPoint(x: x, y: y) }
        if let c = a["coordinate"] {
            if let arr = c as? [Any], arr.count >= 2,
               let x = num(arr[0]), let y = num(arr[1]) { return CGPoint(x: x, y: y) }
            if let obj = c as? [String: Any],
               let x = num(obj["x"]), let y = num(obj["y"]) { return CGPoint(x: x, y: y) }
        }
        if let to = a["to"] as? [String: Any],
           let x = num(to["x"]), let y = num(to["y"]) { return CGPoint(x: x, y: y) }
        return nil
    }

    /// Coerce a JSON number/string into a Double.
    private func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Codex enforces its own app allow/deny list and refuses some apps (e.g.
    /// Terminal). Detect that phrasing so the HUD can show it as a refusal rather
    /// than a generic failed tool.
    private func isRefusal(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let t = text.lowercased()
        return ["not allowed to use", "for safety reasons", "not permitted",
                "can't control", "cannot control", "won't control",
                "refuse", "blocked for safety", "not allowed to control"]
            .contains { t.contains($0) }
    }

    /// Pull the app the action targeted from the tool args, for a readable
    /// refusal line. Falls back to the tool name.
    private func appName(_ item: [String: Any], fallback: String) -> String {
        if let a = argumentsDict(item) {
            for key in ["app", "application", "bundle_id", "bundleId", "target"] {
                if let v = a[key] as? String, !v.isEmpty { return v }
            }
        }
        return fallback
    }

    private func toolResultText(_ item: [String: Any]) -> String {
        guard let result = item["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let first = content.first, let text = first["text"] as? String
        else { return "" }
        return String(text.prefix(120))
    }

    private func append(_ kind: Step.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        steps.append(Step(kind: kind, text: text))
    }

    private func finish() {
        isRunning = false
        process = nil
        CodexLiveOverlay.shared.end()   // fade out the live drawing layer
        // Classify the outcome BEFORE the "Done." fallback, so the router can tell
        // a real result from an empty/soft-failed one and fail over accordingly.
        if stopRequested {
            lastOutcome = .stopped
        } else if steps.contains(where: { $0.kind == .refusal }) || isRefusal(result) {
            lastOutcome = .refused
        } else if result.isEmpty {
            lastOutcome = .failed
        } else if toolFailures > 0 && toolSuccesses == 0 {
            // Attempted actions, none landed → the task didn't actually happen,
            // even if it ended with a polite explanation. Fail over.
            lastOutcome = .failed
        } else if indicatesIncomplete(result) {
            // A "couldn't / denied / you'll need to…" sign-off is a soft failure,
            // not success — let the router try the other engine.
            lastOutcome = .failed
        } else {
            lastOutcome = .succeeded
        }
        if result.isEmpty { result = "Done." }
    }

    /// Final-message language that admits the task wasn't completed. Conservative —
    /// a false positive only costs a failover attempt on the other engine (which
    /// is single-metered), and Tre's priority is "get it done".
    private func indicatesIncomplete(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let t = text.lowercased()
        return ["couldn't", "could not", "cannot ", "can't ", "unable to",
                "wasn't able", "was not able", "approval denied", "denied",
                "you'll need to", "you will need to", "please approve",
                "failed to", "didn't work", "was unable"]
            .contains { t.contains($0) }
    }
}
