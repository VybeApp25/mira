// AICodingBridgeService.swift
// Watches the user's OWN Claude Code / Cursor Agent CLI sessions and answers
// their permission prompts from the notch.
//
// This is deliberately NOT ClaudeCodeBridge. That one SPAWNS `claude` to do
// Mira's work. This one observes sessions the user started in their own
// terminal and never launches anything.
//
// How MacNotch does it (audit §6.5) and why we copy the shape: they don't poll.
// They ship CLI hooks that open a Unix socket, send the tool call, and BLOCK on
// a reply with a timeout, falling back to the terminal prompt when the socket
// isn't there. The blocking-with-fallback part is the design worth taking —
// it means Mira being closed, crashed, or not installed degrades to exactly
// the behavior the user had before, with no hang and no lost session.
//
// Two deliberate divergences:
//
//   • ONE CONNECTION PER EVENT, not a keep-alive registration. MacNotch's hook
//     holds the socket open for the session's life; ours connects, sends, waits
//     for at most one reply, and closes. Session identity comes from the
//     `session_id` in the payload rather than from which fd it arrived on.
//     A keep-alive shell client is hard to write correctly with `nc`, and
//     lifecycle is already covered because Claude Code emits SessionStart /
//     Stop / SessionEnd hook events of its own.
//
//   • A 20s decision window rather than MacNotch's 5s. 5s is not enough time to
//     notice the notch light up and click, so in practice it would time out and
//     fall through nearly every time — which makes the feature theater. 20s is
//     still bounded, and the fallback path is identical.

import Foundation
import Combine
import Darwin

// MARK: - Model

struct AICodingSession: Identifiable, Equatable {

    enum Source: String, Equatable {
        case claudeCode = "claude-code"
        case cursorAgent = "cursor-agent"
        case unknown

        var display: String {
            switch self {
            case .claudeCode:  return "Claude Code"
            case .cursorAgent: return "Cursor Agent"
            case .unknown:     return "CLI"
            }
        }

        var icon: String {
            switch self {
            case .claudeCode:  return "terminal"
            case .cursorAgent: return "cursorarrow.rays"
            case .unknown:     return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    enum Status: Equatable {
        case working        // a tool is running
        case waiting        // blocked on us for an Allow/Deny
        case idle           // turn finished, session still open
        case ended
    }

    /// One line of session history — a tool call, mostly.
    struct Event: Identifiable, Equatable {
        let id = UUID()
        let toolName: String
        /// The one field of `tool_input` worth showing in a strip this narrow:
        /// the command for a shell call, the path for a write.
        let detail: String?
        let at: Date
    }

    let id: String
    var source: Source
    var cwd: String
    var status: Status
    var events: [Event]
    var lastSeen: Date

    /// Set while the CLI is blocked waiting for this session's decision.
    var pending: PendingPermission?

    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct PendingPermission: Equatable {
    let toolName: String
    let detail: String?
    /// Whole `tool_input`, pretty-printed, for the drill-in.
    let fullInput: String
    let askedAt: Date
    let deadline: Date
}

// MARK: - Service

@MainActor
final class AICodingBridgeService: ObservableObject {

    static let shared = AICodingBridgeService()

    @Published private(set) var sessions: [AICodingSession] = []
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    /// How long the CLI is asked to wait for a human. See the file header for
    /// why this is not MacNotch's 5s.
    static let decisionWindow: TimeInterval = 20

    /// Tools that block. Everything else is reported and allowed to proceed —
    /// gating a read is noise, and noise is how a permission prompt becomes
    /// something you click through without reading.
    static let gatedTools: Set<String> = [
        "Bash", "Shell", "Execute", "Write", "Edit", "MultiEdit", "NotebookEdit"
    ]

    /// Per-user so two accounts on one Mac don't fight over the path, and in
    /// /tmp because the socket must not survive a reboot.
    static var socketPath: String { "/tmp/mira-aicoding-\(getuid()).sock" }

    private var server: UnixSocketServer?

    /// Connections parked waiting on a human, keyed by session.
    private var waiting: [String: Int32] = [:]

    private var sweepTimer: AnyCancellable?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard server == nil else { return }
        let server = UnixSocketServer(path: Self.socketPath)
        server.onLine = { [weak self] line, fd in
            Task { @MainActor in self?.handle(line: line, fd: fd) }
        }
        server.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.isListening = false
            }
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            lastError = nil
            startSweep()
        } catch {
            lastError = error.localizedDescription
            isListening = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        sweepTimer = nil
        for fd in waiting.values { UnixSocketServer.close(fd) }
        waiting.removeAll()
    }

    /// Expire pending asks whose window has run out. The CLI has already given
    /// up and fallen back to its own prompt by then, so leaving the Allow/Deny
    /// buttons on screen would offer a decision that no longer connects to
    /// anything — the worst failure mode this feature has.
    private func startSweep() {
        sweepTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sweep() }
    }

    private func sweep() {
        let now = Date()
        for idx in sessions.indices {
            guard let pending = sessions[idx].pending, pending.deadline <= now else { continue }
            let id = sessions[idx].id
            sessions[idx].pending = nil
            sessions[idx].status  = .working
            if let fd = waiting.removeValue(forKey: id) { UnixSocketServer.close(fd) }
        }
        // Drop sessions we haven't heard from in a while. Without this, every
        // terminal ever opened accumulates in the list forever.
        sessions.removeAll { $0.status == .ended && now.timeIntervalSince($0.lastSeen) > 60 }
    }

    // MARK: Decisions

    func respond(sessionID: String, approve: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].pending = nil
        sessions[idx].status  = .working

        guard let fd = waiting.removeValue(forKey: sessionID) else { return }
        let payload = #"{"type":"permission_response","approved":\#(approve)}"# + "\n"
        UnixSocketServer.write(payload, to: fd)
        UnixSocketServer.close(fd)
    }

    // MARK: Ingest

    private func handle(line: String, fd: Int32) {
        guard let data = line.data(using: .utf8),
              let raw  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = raw["session_id"] as? String, !sessionID.isEmpty
        else {
            UnixSocketServer.close(fd)
            return
        }

        let event  = (raw["hook_event_name"] as? String) ?? "PreToolUse"
        let source = AICodingSession.Source(rawValue: (raw["source"] as? String) ?? "") ?? .unknown
        let cwd    = (raw["cwd"] as? String) ?? ""
        let tool   = raw["tool_name"] as? String
        let input  = raw["tool_input"] as? [String: Any]

        var session = sessions.first { $0.id == sessionID }
            ?? AICodingSession(id: sessionID, source: source, cwd: cwd,
                               status: .idle, events: [], lastSeen: Date(), pending: nil)
        session.lastSeen = Date()
        if session.source == .unknown, source != .unknown { session.source = source }
        if session.cwd.isEmpty { session.cwd = cwd }

        var needsReply = false

        switch event {
        case "SessionStart":
            session.status = .idle

        case "SessionEnd":
            session.status = .ended

        case "Stop", "SubagentStop":
            session.status = .idle

        case "PostToolUse":
            session.status = .working

        case "PreToolUse":
            let tool = tool ?? "Tool"
            session.events.append(.init(toolName: tool,
                                        detail: Self.summarize(input),
                                        at: Date()))
            // Keep the tail only. A long session would otherwise grow this
            // array without bound for a UI that shows five rows.
            if session.events.count > 40 { session.events.removeFirst(session.events.count - 40) }

            if Self.gatedTools.contains(tool) {
                session.status = .waiting
                session.pending = PendingPermission(
                    toolName: tool,
                    detail: Self.summarize(input),
                    fullInput: Self.prettyPrint(input),
                    askedAt: Date(),
                    deadline: Date().addingTimeInterval(Self.decisionWindow))
                waiting[sessionID].map(UnixSocketServer.close)   // supersede a stale ask
                waiting[sessionID] = fd
                needsReply = true
            } else {
                session.status = .working
            }

        default:
            break
        }

        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }

        // Everything that isn't a gated PreToolUse is fire-and-forget: close so
        // the hook's `nc` exits immediately instead of sitting on its idle
        // timeout and stalling the CLI for no reason.
        if !needsReply { UnixSocketServer.close(fd) }
    }

    // MARK: Formatting

    /// The one field of a tool input worth a single line.
    static func summarize(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }

    static func prettyPrint(_ input: [String: Any]?) -> String {
        guard let input,
              let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

// MARK: - Socket

/// Minimal line-oriented Unix domain socket server.
///
/// POSIX rather than Network.framework: NWListener has no first-class Unix
/// domain socket path, and the workarounds are more code than this.
///
/// `nonisolated` on purpose — every byte of this runs on `queue`, never on the
/// main actor, and it hands finished lines back through `onLine` for the caller
/// to hop wherever it needs.
final class UnixSocketServer: @unchecked Sendable {

    /// Called with one complete line and the fd it arrived on. The fd is the
    /// CALLER's to close — it stays open so a reply can be written later.
    var onLine: ((String, Int32) -> Void)?
    var onError: ((String) -> Void)?

    private let path: String
    private let queue = DispatchQueue(label: "com.mira.aicoding.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: ConnectionState] = [:]

    private final class ConnectionState {
        var buffer = Data()
        var source: DispatchSourceRead?
    }

    init(path: String) { self.path = path }

    enum SocketError: LocalizedError {
        case create(Int32), bind(Int32), listen(Int32), pathTooLong

        var errorDescription: String? {
            switch self {
            case .pathTooLong:   return "Socket path is too long for sockaddr_un."
            case .create(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .bind(let e):   return "bind() failed: \(String(cString: strerror(e)))"
            case .listen(let e): return "listen() failed: \(String(cString: strerror(e)))"
            }
        }
    }

    func start() throws {
        // A stale socket file from a crash makes bind() fail with EADDRINUSE
        // forever, which would look like "the feature just stopped working".
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let e = errno; Darwin.close(fd); throw SocketError.bind(e)
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let e = errno; Darwin.close(fd); unlink(path); throw SocketError.listen(e)
        }

        // Non-blocking is not an optimization here, it is required for
        // correctness. `acceptPending` drains in a loop on a SERIAL queue; with
        // a blocking listen fd the accept after the last pending connection
        // blocks that queue forever, and the connection's own read source —
        // scheduled on the same queue — can then never run. The symptom is a
        // socket that accepts happily and delivers nothing.
        Self.setNonBlocking(fd)

        // Only this user's processes may talk to it. The hook runs as the same
        // user, and anything else asking to approve shell commands on their
        // behalf has no business being answered.
        chmod(path, 0o600)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for (fd, state) in connections {
                state.source?.cancel()
                Darwin.close(fd)
            }
            connections.removeAll()
            if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
            unlink(path)
        }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func acceptPending() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            // EAGAIN here just means the backlog is drained — the normal exit.
            guard fd >= 0 else { return }
            Self.setNonBlocking(fd)

            let state = ConnectionState()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { [weak self] in
                self?.connections.removeValue(forKey: fd)
            }
            state.source = source
            connections[fd] = state
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let state = connections[fd] else { return }

        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }   // not ready; not EOF
        guard n > 0 else {
            // EOF or error: the peer went away mid-message.
            state.source?.cancel()
            Darwin.close(fd)
            return
        }
        state.buffer.append(contentsOf: chunk[0..<n])

        // A hook sends exactly one line. Take the first complete one and stop
        // reading this connection — anything after it is not part of the
        // protocol, and continuing to parse would let a malformed sender drive
        // the UI with a stream of events.
        guard let newline = state.buffer.firstIndex(of: 0x0A) else {
            if state.buffer.count > 1_048_576 {   // 1 MB of no newline: not ours
                state.source?.cancel()
                Darwin.close(fd)
            }
            return
        }

        let lineData = state.buffer[state.buffer.startIndex..<newline]
        state.source?.cancel()
        state.source = nil

        guard let line = String(data: lineData, encoding: .utf8) else {
            Darwin.close(fd)
            return
        }
        onLine?(line, fd)
    }

    // MARK: fd helpers

    static func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer {
                Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }

    static func close(_ fd: Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
    }
}
