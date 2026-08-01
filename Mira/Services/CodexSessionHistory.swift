// CodexSessionHistory.swift
// Past Codex sessions, read from the rollout transcripts Codex already writes.
//
// This is the "history context" half of the desktop-app work, and it is worth
// being precise about WHICH histories are actually reachable, because the answer
// is not uniform and it decides what is cheap and what is expensive:
//
//   • Claude Code  ~/.claude/projects/**.jsonl              READABLE (already
//                                                            read by
//                                                            ClaudeCodeSessionWatcher)
//   • Claude Cowork  local-agent-mode-sessions/*.json       READABLE
//   • Codex CLI    ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl   READABLE — here
//   • ChatGPT desktop  conversations-v3-<user>/*.data       ENCRYPTED. 83
//     conversations, every one high-entropy with no header. Not a format to
//     parse; a key we do not have and should not want.
//   • Claude Desktop   IndexedDB leveldb                    NO PLAIN TEXT.
//
// So CLI history is free and rich, and the two DESKTOP apps' histories are not
// available on disk at all. Reaching an old chat in those means driving the
// app's own search and reading the screen — expensive, and a completely
// different mechanism from this file.
//
// SIZE IS THE REAL CONSTRAINT HERE. The largest rollout on this Mac is 95 MB.
// Reading these with String(contentsOf:) would pull ~100 MB into memory to
// recover a title, per session, on a list refresh. Everything below is bounded:
// the metadata is on the FIRST line, and the first real user message arrives
// early, so only a prefix is ever read.

import Foundation

@MainActor
final class CodexSessionHistory: ObservableObject {

    static let shared = CodexSessionHistory()

    struct Session: Identifiable, Equatable {
        let id: String
        let cwd: String
        let startedAt: Date
        /// First genuine user message, which reads far better as a title than a
        /// UUID or a folder name.
        let opening: String?
        let path: URL

        var displayName: String {
            if let opening, !opening.isEmpty { return opening }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? "Codex session" : leaf
        }
    }

    @Published private(set) var sessions: [Session] = []

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.root.path) }

    private init() {}

    /// Newest first. `limit` bounds the work: a user with hundreds of sessions
    /// should not pay for all of them to show a list of eight.
    func refresh(limit: Int = 12) {
        guard isAvailable else { return }

        let files = rolloutFiles()
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // name carries the timestamp
            .prefix(limit)

        var found: [Session] = []
        for url in files {
            guard let session = parse(url) else { continue }
            found.append(session)
        }
        found.sort { $0.startedAt > $1.startedAt }
        if found != sessions { sessions = found }
    }

    private func rolloutFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: Self.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker
        where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            out.append(url)
            if out.count > 500 { break }
        }
        return out
    }

    /// Reads only a bounded prefix — never the whole file.
    private func parse(_ url: URL) -> Session? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 512 KB is comfortably past the metadata line and the opening exchange,
        // and is a rounding error against a 95 MB transcript.
        guard let chunk = try? handle.read(upToCount: 512 * 1024),
              let text = String(data: chunk, encoding: .utf8) else { return nil }

        var id = ""
        var cwd = ""
        var started: Date?
        var opening: String?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let payload = entry["payload"] as? [String: Any] ?? [:]

            if entry["type"] as? String == "session_meta" {
                id = payload["id"] as? String ?? ""
                cwd = payload["cwd"] as? String ?? ""
                if let stamp = payload["timestamp"] as? String { started = formatter.date(from: stamp) }
                continue
            }

            if opening == nil, payload["role"] as? String == "user",
               let body = Self.text(from: payload["content"]) {
                // Codex injects an <environment_context> block as the first user
                // turn. It is machinery, not something the user typed, and using
                // it as the title would label every session identically.
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.hasPrefix("<environment_context>"), trimmed.count > 2 {
                    opening = String(trimmed.prefix(120))
                }
            }
        }

        guard !id.isEmpty else { return nil }
        return Session(id: id,
                       cwd: cwd,
                       startedAt: started ?? fileDate(url),
                       opening: opening,
                       path: url)
    }

    /// Content is either a string or an array of `{type,text}` parts.
    private static func text(from content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func fileDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Full text of one session, for handing to a model as context.
    ///
    /// Capped hard. The largest rollout here is 95 MB, and "load the transcript"
    /// with no ceiling is how a context feature becomes an out-of-memory crash
    /// on someone else's machine.
    func transcript(_ session: Session, maxBytes: Int = 400_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: session.path) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: maxBytes),
              let text = String(data: chunk, encoding: .utf8) else { return nil }

        var lines: [String] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any],
                  let role = payload["role"] as? String,
                  let body = Self.text(from: payload["content"]),
                  !body.hasPrefix("<environment_context>")
            else { continue }
            lines.append("\(role): \(body)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}
