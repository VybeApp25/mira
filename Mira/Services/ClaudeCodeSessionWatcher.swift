// ClaudeCodeSessionWatcher.swift
// Discovers Claude Code sessions with ZERO setup, by reading the transcripts
// the CLI already writes to ~/.claude/projects/<slug>/<session-uuid>.jsonl.
//
// Why this exists: the first cut of AI Coding only had the hook path, so a
// session was invisible until the user installed a hook into their own
// settings.json. That is backwards, and MacNotch's own feature copy says so
// outright — "Works via file monitoring, hooks are optional for faster event
// notifications." Detection and gating are separable:
//
//   • DETECTION (this file) — which sessions exist, what they're doing, what
//     they've spent. Needs nothing installed. Reads files Claude Code already
//     writes.
//   • GATING (AICodingBridgeService + the hook) — Allow/Deny while the CLI is
//     blocked. Genuinely needs the hook, because nothing on disk can answer a
//     prompt that is waiting on stdin.
//
// So the module works out of the box and the hook becomes an upgrade rather
// than a gate.
//
// Reading is incremental: each file keeps a byte offset and running totals, and
// a refresh parses only what was appended. A long session's transcript reaches
// tens of megabytes, and re-reading all of them every few seconds to redraw a
// five-row list would be the most expensive thing Mira does.

import Foundation
import Combine

// MARK: - Model

struct ClaudeCodeTranscript: Identifiable, Equatable {

    struct Step: Identifiable, Equatable {
        let id = UUID()
        let toolName: String
        let detail: String?
        let at: Date
    }

    struct Tokens: Equatable {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0

        /// What the user is actually billed attention for. Cache reads are
        /// deliberately excluded from the headline number — on a long session
        /// they dwarf everything else and make the figure meaningless.
        var billable: Int { input + output }
    }

    let id: String            // sessionId
    var cwd: String
    /// Directory name under ~/.claude/projects — Claude Code's slug for the
    /// project root. Used to match a transcript to a running process; see
    /// `ClaudeCodeSessionWatcher.slug(for:)` for why this direction and not the
    /// other.
    var projectSlug: String = ""
    /// The app hosting the terminal this session is running in ("Terminal",
    /// "iTerm2", "Ghostty"…). Nil when the session isn't running, or when the
    /// process tree doesn't reach a GUI app.
    var host: String?
    /// Whether a `claude` process for this project is alive right now.
    var isRunning = false
    var gitBranch: String?
    /// Claude Code's own generated title for the session, when it has written
    /// one. Much better than a folder name, which is identical across the four
    /// sessions someone has open on the same repo.
    var title: String?
    var lastActivity: Date
    var steps: [Step]
    var tokens: Tokens
    var model: String?
    /// True when the newest entry is an assistant tool_use with no matching
    /// result yet — the CLI is mid-tool.
    var isMidTool: Bool
    /// The user's most recent prompt, which Claude Code records outright as a
    /// `last-prompt` entry. This is what makes a row identifiable at a glance —
    /// a title tells you the topic, the prompt tells you where you left off.
    var lastPrompt: String?
    /// User and assistant turns seen. Tail-accurate on large transcripts, like
    /// the token totals, for the same reason.
    var messageCount = 0

    /// Short model name for a chip: `claude-opus-5` becomes `Opus`.
    var modelLabel: String? {
        guard let model else { return nil }
        let parts = model.components(separatedBy: "-")
        guard let family = parts.first(where: {
            ["opus", "sonnet", "haiku", "fable"].contains($0.lowercased())
        }) else { return model }
        return family.capitalized
    }

    var folderName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return folderName.isEmpty ? "Claude Code" : folderName
    }

    /// What the session IS, in the words someone would use out loud —
    /// "Claude Code in Terminal". Falls back gracefully as knowledge runs out:
    /// a running session with no resolvable host is still Claude Code, and a
    /// session that has exited is described by where it ran.
    var sourceLabel: String {
        guard isRunning else { return folderName }
        guard let host, !host.isEmpty else { return "Claude Code" }
        return "Claude Code in \(host)"
    }
}

// MARK: - Watcher

@MainActor
final class ClaudeCodeSessionWatcher: ObservableObject {

    static let shared = ClaudeCodeSessionWatcher()

    @Published private(set) var transcripts: [ClaudeCodeTranscript] = []
    /// Number of `claude` processes running. Used only to distinguish "this
    /// session is live" from "this transcript is just the most recent one on
    /// disk" — a transcript keeps its mtime forever after the CLI exits.
    @Published private(set) var liveProcessCount = 0

    /// Transcripts older than this are not sessions, they're history.
    nonisolated static let recencyWindow: TimeInterval = 12 * 3600

    /// A session that hasn't written for this long is idle rather than working.
    /// `nonisolated` so row models can classify status without hopping actors.
    nonisolated static let activeWindow: TimeInterval = 90

    private var timer: AnyCancellable?
    private var cursors: [String: Cursor] = [:]

    /// Per-file incremental parse state.
    private final class Cursor {
        var offset: UInt64 = 0
        var partial = Data()
        var transcript: ClaudeCodeTranscript
        init(transcript: ClaudeCodeTranscript) { self.transcript = transcript }
    }

    private var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private init() {}

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: projectsDirectory.path)
    }

    func start(interval: TimeInterval = 3) {
        guard timer == nil else { return }
        refresh()
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() { timer = nil }

    // MARK: Refresh

    func refresh() {
        let files = recentTranscriptFiles()
        let paths = Set(files.map(\.path))

        // Drop cursors for files that aged out, so a machine left running for a
        // week doesn't accumulate parse state for every session ever.
        cursors = cursors.filter { paths.contains($0.key) }

        for url in files { ingest(url) }

        var all = cursors.values
            .map(\.transcript)
            .sorted { $0.lastActivity > $1.lastActivity }

        // Attach liveness and host app by matching each running process's real
        // cwd to the project slug its transcripts live under.
        let processes = Self.runningClaudeProcesses()
        liveProcessCount = processes.count

        var bySlug: [String: RunningProcess] = [:]
        for process in processes {
            guard let cwd = process.cwd else { continue }
            bySlug[Self.slug(for: cwd)] = process
        }

        var claimed = Set<String>()
        for index in all.indices {
            let slug = all[index].projectSlug
            guard let process = bySlug[slug], !claimed.contains(slug) else { continue }
            // Several sessions can share a project directory, but only one
            // process is running there. Give it to the most recently active
            // transcript — `all` is already sorted, so the first match wins and
            // the rest correctly read as finished.
            claimed.insert(slug)
            all[index].isRunning = true
            all[index].host = process.host
        }

        transcripts = all
    }

    /// `~/.claude/projects/<slug>/<uuid>.jsonl`, touched recently.
    private func recentTranscriptFiles() -> [URL] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-Self.recencyWindow)
        var out: [(URL, Date)] = []

        for project in projects {
            guard let files = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                      modified > cutoff else { continue }
                out.append((file, modified))
            }
        }

        // Cap the working set. Someone with a hundred old sessions in the window
        // does not want a hundred rows, and we'd be parsing all of them.
        return out.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    /// Read whatever was appended since last time and fold it in.
    private func ingest(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let sessionID = url.deletingPathExtension().lastPathComponent

        let cursor: Cursor
        if let existing = cursors[url.path] {
            cursor = existing
        } else {
            cursor = Cursor(transcript: ClaudeCodeTranscript(
                id: sessionID, cwd: "",
                projectSlug: url.deletingLastPathComponent().lastPathComponent,
                host: nil, isRunning: false,
                gitBranch: nil, title: nil,
                lastActivity: .distantPast, steps: [], tokens: .init(),
                model: nil, isMidTool: false))
            cursors[url.path] = cursor
        }

        // A shrinking file means it was rotated or replaced; re-read from zero
        // rather than parsing from a now-meaningless offset.
        if size < cursor.offset {
            cursor.offset = 0
            cursor.partial = Data()
        }
        guard size > cursor.offset else { return }

        // First read of a long-running session: skip to the tail. The list shows
        // five steps and a token total, and paying to parse 40 MB of history for
        // that on the first refresh would stall the UI at launch. Totals are
        // then tail-accurate rather than session-accurate, which is the honest
        // trade and why the label says "recent".
        let maxInitial: UInt64 = 512 * 1024
        if cursor.offset == 0, size > maxInitial {
            cursor.offset = size - maxInitial
        }

        try? handle.seek(toOffset: cursor.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        cursor.offset = size

        var buffer = cursor.partial
        buffer.append(chunk)

        // Keep only whole lines; stash any trailing fragment for next time.
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(buffer[start..<newline])
            start = buffer.index(after: newline)
        }
        cursor.partial = Data(buffer[start...])
        // A single line this large is not something we can use, and holding it
        // would grow without bound.
        if cursor.partial.count > 4 * 1024 * 1024 { cursor.partial = Data() }

        for line in lines { apply(line: line, to: cursor) }
    }

    private func apply(line: Data, to cursor: Cursor) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        var t = cursor.transcript
        let type = object["type"] as? String ?? ""

        if let cwd = object["cwd"] as? String, !cwd.isEmpty { t.cwd = cwd }
        if let branch = object["gitBranch"] as? String, !branch.isEmpty { t.gitBranch = branch }
        if let title = object["aiTitle"] as? String, !title.isEmpty { t.title = title }
        if let prompt = object["lastPrompt"] as? String, !prompt.isEmpty {
            t.lastPrompt = prompt.replacingOccurrences(of: "\n", with: " ")
        }
        if type == "user" || type == "assistant", (object["isMeta"] as? Bool) != true {
            t.messageCount += 1
        }
        if let stamp = object["timestamp"] as? String,
           let date = Self.isoFormatter.date(from: stamp) {
            t.lastActivity = max(t.lastActivity, date)
        }

        // Sidechain entries are subagent traffic. Folding their tool calls into
        // the parent's step list makes a session look like it is doing things
        // the user never asked for.
        let isSidechain = (object["isSidechain"] as? Bool) ?? false

        if type == "assistant", let message = object["message"] as? [String: Any] {
            if let model = message["model"] as? String { t.model = model }

            if let usage = message["usage"] as? [String: Any] {
                t.tokens.input      += (usage["input_tokens"] as? Int) ?? 0
                t.tokens.output     += (usage["output_tokens"] as? Int) ?? 0
                t.tokens.cacheRead  += (usage["cache_read_input_tokens"] as? Int) ?? 0
                t.tokens.cacheWrite += (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            var sawToolUse = false
            if !isSidechain, let content = message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" {
                    sawToolUse = true
                    let name = (block["name"] as? String) ?? "Tool"
                    t.steps.append(.init(toolName: Self.friendlyToolName(name),
                                         detail: AICodingBridgeService.summarize(block["input"] as? [String: Any]),
                                         at: t.lastActivity))
                }
            }
            if sawToolUse { t.isMidTool = true }
            if t.steps.count > 20 { t.steps.removeFirst(t.steps.count - 20) }
        }

        // A user entry after a tool_use is the tool result coming back.
        if type == "user" { t.isMidTool = false }

        cursor.transcript = t
    }

    /// MCP tools arrive as `mcp__server__tool`, which is unreadable in a chip.
    static func friendlyToolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let parts = raw.dropFirst(5).components(separatedBy: "__")
        guard let last = parts.last, !last.isEmpty else { return raw }
        return last
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: Processes

    /// A live `claude` CLI process, with enough context to name it in the UI.
    struct RunningProcess {
        let pid: pid_t
        let cwd: String?
        /// Bundle name of the GUI app the process tree leads back to.
        let host: String?
    }

    /// Every running `claude` CLI process.
    ///
    /// libproc rather than shelling out to `pgrep`. The first version used
    /// pgrep and reported zero while a session was demonstrably running — under
    /// a sandboxed launch context pgrep can enumerate pids but cannot read the
    /// names it matches against, so every name query comes back empty and the
    /// failure is silent. libproc asks the kernel directly, spawns nothing, and
    /// costs microseconds.
    static func runningClaudeProcesses() -> [RunningProcess] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, byteCount)
        }
        guard written > 0 else { return [] }

        var out: [RunningProcess] = []
        for pid in pids.prefix(Int(written)) where pid > 0 {
            guard let path = executablePath(pid), isClaudeCodeExecutable(path) else { continue }
            out.append(RunningProcess(pid: pid,
                                      cwd: workingDirectory(pid),
                                      host: hostApplication(of: pid)))
        }
        return out
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let capacity = UInt32(buffer.count)
        let n = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, capacity)
        }
        return n > 0 ? String(cString: buffer) : nil
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard n == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// Walk up the process tree until we hit something inside a .app bundle,
    /// and report that bundle's name — "Terminal", "iTerm2", "Ghostty".
    ///
    /// Deliberately generic rather than a list of known terminals: the chain for
    /// a stock setup is claude → zsh → login → Terminal.app, and any terminal
    /// emulator ends the same way. A hardcoded list would silently fail on
    /// whatever the user actually uses.
    static func hostApplication(of pid: pid_t) -> String? {
        var current = pid
        // Bounded because a corrupt ppid chain could otherwise loop forever.
        for _ in 0..<16 {
            guard let parent = parentPID(current), parent > 1 else { return nil }
            if let path = executablePath(parent),
               let range = path.range(of: ".app/Contents/MacOS/") {
                let bundle = String(path[path.startIndex..<range.lowerBound])
                return (bundle as NSString).lastPathComponent
            }
            current = parent
        }
        return nil
    }

    /// Short BSD info, not the full struct. `login` sits between the shell and
    /// the terminal app and is owned by root; PROC_PIDTBSDINFO on it fails for
    /// an unprivileged caller, which broke the walk one step short of the
    /// answer every single time. PROC_PIDT_SHORTBSDINFO is readable across
    /// users and carries the ppid, which is all this needs.
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let n = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, $0, size)
        }
        return n == size ? pid_t(info.pbsi_ppid) : nil
    }

    /// Claude Code's directory name for a project root: the absolute path with
    /// every separator replaced by a dash, so /Users/tre becomes -Users-tre.
    ///
    /// Computed in THIS direction only. Going back the other way is ambiguous —
    /// `-Users-tre-ai-website-cloner` could be `ai-website-cloner` or
    /// `ai/website/cloner`, and there is no way to tell from the slug. Deriving
    /// the slug from a process's real cwd is exact.
    static func slug(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// Whether an executable path belongs to the Claude Code CLI.
    ///
    /// Not a name comparison and not a substring search, both of which were
    /// wrong in testing. `proc_name` reports "2.1.220" for the native install,
    /// because that installer names the binary after its version
    /// (~/.local/share/claude/versions/<version>). And a loose contains-"claude"
    /// test matches any process whose path merely mentions the word — during
    /// development it matched a scratch binary sitting under /tmp/claude-501.
    static func isClaudeCodeExecutable(_ path: String) -> Bool {
        if path.contains("/.local/share/claude/versions/") { return true }
        // npm-global, Homebrew and /usr/local installs keep the plain name.
        return (path as NSString).lastPathComponent == "claude"
    }
}
