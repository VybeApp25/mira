import AppKit

// MARK: - UsageLogService
//
// Opt-in, LOCAL-ONLY rolling log of which apps the user works in, used to
// personalize proactive agent recommendations (HeyClicky-parity). Text-only:
// app name + bundle id + timestamp — never window contents, keystrokes, or
// screenshots. Stored on disk, ring-capped, and only ever leaves the machine as
// a small AGGREGATED digest (top apps + counts) at recommendation time.
// Gated by `mira_usage_log_enabled` (default OFF — the user opts in).
// See docs/specs/heyclicky-parity-proactive-and-skills.md (Gap A, Privacy).

private struct UsageEvent: Codable {
    let t: Date
    let app: String
    let bundleID: String
}

@MainActor
final class UsageLogService {
    static let shared = UsageLogService()
    private init() {}

    static let enabledKey = "mira_usage_log_enabled"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private let maxRows = 5_000
    private let retention: TimeInterval = 14 * 24 * 60 * 60   // 14 days
    private let minDwell: TimeInterval = 5                    // ignore rapid app flips

    private var started = false
    private var lastBundle: String?
    private var lastRecorded = Date.distantPast

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-log.jsonl")
    }()

    // MARK: - Lifecycle (driven by the opt-in toggle / launch)

    func startIfEnabled() {
        guard isEnabled, !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        record(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        guard started else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        started = false
        lastBundle = nil
    }

    /// Delete all stored usage history (Settings "Clear usage history").
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Capture

    @objc private func appDidActivate(_ note: Notification) {
        record(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier else { return }
        // Skip Mira itself and rapid flips back to the same app.
        if bundleID == Bundle.main.bundleIdentifier { return }
        let now = Date()
        if bundleID == lastBundle && now.timeIntervalSince(lastRecorded) < minDwell { return }
        lastBundle = bundleID
        lastRecorded = now

        let name = app.localizedName ?? bundleID
        let event = UsageEvent(t: now, app: name, bundleID: bundleID)
        append(event)
    }

    private func append(_ event: UsageEvent) {
        var events = loadEvents()
        events.append(event)
        // Ring-cap by age then by row count.
        let cutoff = Date().addingTimeInterval(-retention)
        events = events.filter { $0.t > cutoff }
        if events.count > maxRows { events = Array(events.suffix(maxRows)) }
        writeEvents(events)
    }

    // MARK: - Digest (the ONLY thing that leaves the machine)

    /// A compact, aggregated summary — "AppName: N sessions" for the top apps over
    /// the window. No timeline, no per-event detail.
    func digest(days: Int = 7, topN: Int = 12) -> String {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let recent = loadEvents().filter { $0.t > cutoff }
        guard !recent.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for e in recent { counts[e.app, default: 0] += 1 }
        let lines = counts.sorted { $0.value > $1.value }
            .prefix(topN)
            .map { "- \($0.key): \($0.value) switches" }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSONL storage

    private func loadEvents() -> [UsageEvent] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? dec.decode(UsageEvent.self, from: data)
        }
    }

    private func writeEvents(_ events: [UsageEvent]) {
        let enc = JSONEncoder()
        let lines = events.compactMap { e -> String? in
            guard let data = try? enc.encode(e) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
