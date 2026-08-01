// ClaudeCoworkSessionWatcher.swift
// Claude Cowork sessions from Claude DESKTOP, alongside the Claude Code sessions
// the AI Coding module already lists.
//
// MacNotch added the same thing ("AI Coding now surfaces Claude Cowork sessions
// from Claude Desktop alongside Claude Code and Cursor Agent"), and it is the
// last item on the parity list for this module.
//
// WHERE THE DATA IS. Not in ~/.claude/projects, which is Claude Code's own
// transcript store and holds nothing about Cowork. Claude Desktop keeps one JSON
// file per session under:
//
//     ~/Library/Application Support/Claude/local-agent-mode-sessions/
//         <workspace-uuid>/<subdir>/local_<uuid>.json
//
// Each carries `sessionId`, `title`, `cwd`, `model`, `createdAt`,
// `lastActivityAt` and `isArchived` — verified against the real directory, which
// held 323 files of which exactly 3 were sessions. So the tree is NOT all
// sessions and every file has to be checked for the marker key rather than
// assumed by location.
//
// TIMESTAMPS ARE EPOCH MILLISECONDS, not seconds and not a formatted string —
// dividing is the difference between "2 minutes ago" and a date in the year
// 58000.
//
// This is read-only and lazy: it stats the directory and re-reads only when
// something changed, for the same reason the notification store does. A JSON
// parse of every session on a 3s timer to render a list nobody has open is a
// cost with no reader.

import Foundation
import Combine

@MainActor
final class ClaudeCoworkSessionWatcher: ObservableObject {

    static let shared = ClaudeCoworkSessionWatcher()

    struct Session: Identifiable, Equatable {
        let id: String
        let title: String?
        /// Claude Desktop's sandbox path for the session, e.g. `/sessions/
        /// trusting-modest-darwin`. Not a real path on this Mac, so it is shown
        /// as a label and never opened.
        let cwd: String
        let model: String?
        let lastActivity: Date
        let isArchived: Bool

        var displayName: String {
            if let title, !title.isEmpty { return title }
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? "Cowork session" : leaf
        }

        /// "sonnet-4-6" reads better in a narrow row than the full id.
        var shortModel: String? {
            guard let model else { return nil }
            return model.replacingOccurrences(of: "claude-", with: "")
        }
    }

    @Published private(set) var sessions: [Session] = []

    /// True when Claude Desktop has ever written a session here — the module
    /// hides the whole section otherwise rather than showing an empty list to
    /// someone who does not use Cowork.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.root.path)
    }

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    private var timer: Timer?
    private var lastSignature = ""

    private init() {}

    func start(interval: TimeInterval = 8) {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard isAvailable else { return }
        let files = Self.sessionFiles()

        // Cheap change check before parsing: modification dates and count.
        let signature = files
            .map { url -> String in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(url.lastPathComponent)@\(date)"
            }
            .joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature

        var found: [Session] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["sessionId"] as? String
            else { continue }   // most files here are not sessions

            // Epoch MILLISECONDS. Falls back to createdAt for a session that has
            // been opened but not yet worked in.
            let raw = (json["lastActivityAt"] as? Double)
                ?? (json["createdAt"] as? Double) ?? 0
            let lastActivity = Date(timeIntervalSince1970: raw / 1000)

            found.append(Session(id: id,
                                 title: json["title"] as? String,
                                 cwd: json["cwd"] as? String ?? "",
                                 model: json["model"] as? String,
                                 lastActivity: lastActivity,
                                 isArchived: json["isArchived"] as? Bool ?? false))
        }

        let visible = found
            .filter { !$0.isArchived }
            .sorted { $0.lastActivity > $1.lastActivity }
        if visible != sessions { sessions = visible }
    }

    private static func sessionFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "json" {
            out.append(url)
            // A runaway walk over someone's Application Support is not worth a
            // list of five rows.
            if out.count > 400 { break }
        }
        return out
    }
}
