// RemoteControlService.swift
// A Claude Code session Mira drives from the notch: send prompts, watch replies
// stream back, approve tools, then hand it to Terminal when you want it back.
//
// WHY THIS SHAPE, given MacNotch does it differently.
//
// MacNotch's Remote Control attaches to Claude Code's own `--remote-control`
// feature, which normally relays through Anthropic (claude.ai/code and the
// mobile app). Their binary carries "Could not create TLS identity for Remote
// Control server" and a certificate CN of beacon.claude-ai.staging.ant.dev, so
// they stand up a local TLS server impersonating that endpoint and point the
// CLI at it.
//
// Mira does not do that. Forging a certificate for an Anthropic hostname to
// intercept a first-party channel is not something to ship, and the protocol
// behind it is undocumented and on a staging domain, so it would break without
// warning. There is a supported interface that delivers the same capability:
//
//     claude --print --input-format stream-json --output-format stream-json
//
// which is a documented bidirectional channel. Mira owns the process, so there
// is nothing to intercept and no identity to impersonate. Verified before this
// was written: one process serves many turns, keeps a single session_id, and
// stays alive between them.
//
// The one thing this cannot do is attach to a session you already started in
// your own terminal. Neither can MacNotch — their banner says they open a
// *companion* Terminal tab. Sessions started elsewhere stay read-only here,
// with Allow/Deny through the hook, which is what AICodingBridgeService is for.

import Foundation
import Combine

@MainActor
final class RemoteControlService: ObservableObject {

    static let shared = RemoteControlService()

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case launching
        /// Waiting for you to type.
        case ready
        /// Claude is working — a reply or a tool call is in flight.
        case working
        case ended(String?)

        var isLive: Bool {
            switch self {
            case .ready, .working, .launching: return true
            case .idle, .ended:                return false
            }
        }
    }

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant, tool, system }
        let id = UUID()
        let role: Role
        let text: String
        let at: Date
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var messages: [Message] = []
    @Published private(set) var sessionID: String?
    @Published private(set) var directory: String?
    @Published private(set) var model: String?
    @Published private(set) var costUSD: Double = 0
    @Published private(set) var lastError: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()

    private init() {}

    // MARK: - Executable

    /// Same resolution ClaudeCodeBridge uses, plus the native installer's path,
    /// which names the binary after its version rather than "claude".
    static var executable: String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        // ~/.local/share/claude/versions/<version> — pick the newest.
        let versions = "\(home)/.local/share/claude/versions"
        if let entries = try? fm.contentsOfDirectory(atPath: versions) {
            candidates += entries.sorted(by: >).map { "\(versions)/\($0)" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { Self.executable != nil }

    // MARK: - Launch

    func launch(in directory: String) {
        guard !phase.isLive else { return }
        guard let executable = Self.executable else {
            lastError = "Claude Code isn't installed."
            phase = .ended(lastError)
            return
        }

        messages.removeAll()
        sessionID = nil
        model = nil
        costUSD = 0
        lastError = nil
        self.directory = directory
        phase = .launching

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // REQUIRED, and the first version's omission was a real hole.
            // --print defaults to permissionMode=bypassPermissions, so leaving
            // this off meant a notch-controlled session ran every tool with no
            // approval at all while the panel implied otherwise — confirmed by
            // running one and watching a Bash execute unasked. `manual` makes
            // every tool call ask, which is what routes it to the PreToolUse
            // hook and into the notch as Allow/Deny.
            "--permission-mode", "manual"
        ]

        var environment = ProcessInfo.processInfo.environment
        // Marks the session as Mira-launched for anything downstream that cares,
        // and keeps it out of the terminal's own notion of an interactive TTY.
        environment["MIRA_REMOTE_CONTROL"] = "1"
        process.environment = environment

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput  = inPipe
        process.standardOutput = outPipe
        process.standardError  = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }

        // stderr is only interesting when something has gone wrong; the CLI puts
        // its real output on stdout.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            Task { @MainActor in RemoteControlService.shared.lastError = text }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.teardown(reason: proc.terminationStatus == 0
                               ? nil
                               : "Claude Code exited (\(proc.terminationStatus)).")
            }
        }

        do {
            try process.run()
        } catch {
            lastError = error.localizedDescription
            phase = .ended(lastError)
            return
        }

        self.process = process
        self.stdin = inPipe.fileHandleForWriting

        // Ready the moment the process is up, NOT when `system/init` arrives.
        // The CLI emits nothing at all until it receives its first user message
        // — verified: six seconds of silence on a freshly spawned process — so
        // waiting for init before enabling the composer deadlocks. init still
        // arrives, and fills in the session id and model when it does.
        phase = .ready
    }

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase.isLive, let stdin else { return }

        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": trimmed]]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        messages.append(.init(role: .user, text: trimmed, at: Date()))
        phase = .working

        var line = data
        line.append(0x0A)
        // Writes can throw once the child is gone; a crashed CLI shouldn't take
        // the app with it.
        do { try stdin.write(contentsOf: line) }
        catch { teardown(reason: "Lost the connection to Claude Code.") }
    }

    func stop() {
        process?.terminate()
        teardown(reason: nil)
    }

    private func teardown(reason: String?) {
        stdin = nil
        process = nil
        stdoutBuffer = Data()
        if case .ended = phase { return }
        phase = .ended(reason)
    }

    // MARK: - Hand back to Terminal

    /// MacNotch's "Continue in terminal". Resumes THIS session by id, so the
    /// conversation you started in the notch carries over rather than starting
    /// again from nothing.
    func continueInTerminal() {
        guard let sessionID, let directory else { return }
        let command = "cd \(Self.shellQuoted(directory)) && claude --resume \(sessionID)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptEscaped(command))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()

        // The CLI refuses to resume a session that is still open elsewhere, so
        // let go of it here rather than leaving two owners of one session.
        stop()
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Stream decoding

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)

        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: newline)...])
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["session_id"] as? String, sessionID == nil { sessionID = id }

        switch object["type"] as? String {
        case "system":
            // `init` repeats — it is re-emitted per turn, not once per session,
            // so it can only ever fill in detail, never reset state.
            guard object["subtype"] as? String == "init" else { return }
            if let m = object["model"] as? String { model = m }
            if case .launching = phase { phase = .ready }

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            if let m = message["model"] as? String { model = m }

            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { messages.append(.init(role: .assistant, text: text, at: Date())) }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let detail = AICodingBridgeService.summarize(block["input"] as? [String: Any])
                    messages.append(.init(role: .tool,
                                          text: detail.map { "\(name) — \($0)" } ?? name,
                                          at: Date()))
                default:
                    continue
                }
            }

        case "result":
            if let cost = object["total_cost_usd"] as? Double { costUSD = cost }
            if (object["is_error"] as? Bool) == true {
                let text = object["result"] as? String ?? "The turn failed."
                messages.append(.init(role: .system, text: text, at: Date()))
            }
            phase = .ready

        default:
            return
        }

        // Keep the transcript bounded; the panel shows the tail and a long
        // session would otherwise grow this array without limit.
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
    }
}
