// NotificationCenterStore.swift
// Reads delivered notifications out of Notification Center's own database.
//
// WHY THIS EXISTS, replacing an accessibility walk that looked fine.
//
// The first implementation walked com.apple.notificationcenterui's AX tree,
// which is what MacNotch's permission copy implies ("notification-banner
// observation"). On this Mac it returns nothing, ever — and not because of a
// missing permission. Traced it properly:
//
//   • Mira IS accessibility-trusted (the panel shows its empty state, not its
//     permission state).
//   • NotificationCenter's bundle id matches what we look for.
//   • No Focus mode is active.
//   • NotificationCenter has NO on-screen window most of the time, and while it
//     does the tree holds only structural groups.
//   • Yet the notifications are unquestionably arriving: com.apple.mobilesms at
//     14:04:43 for a text Tre sent himself, alongside earlier ones.
//
// An AX walk can only see a banner while it is on screen. That window is short,
// a 3s poll misses most of them, and anything delivered quietly is invisible to
// it entirely. The database is the actual record of what arrived, which is why
// MacNotch asks for Full Disk Access — a permission a banner observer would not
// need.
//
// PRIVACY. This reads message CONTENT, because that is what a notification is.
// It never leaves the machine and is never sent to a model; it goes to the strip
// and the panel. Mira needs Full Disk Access for it, and without that grant this
// returns nothing rather than failing loudly — the AX path stays as a fallback.

import Foundation
import SQLite3
import AppKit

struct NotificationCenterStore {

    /// `~/Library/Group Containers/group.com.apple.usernoted/db2/db`
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: databaseURL.path)
    }

    /// Snapshot the database before reading it.
    ///
    /// Opening the live file read-only fails or reads stale pages when SQLite is
    /// in WAL mode, and Mira has no business taking a lock on a system database
    /// it does not own. Copying costs a couple of milliseconds on a file of this
    /// size and only happens when the modification date has actually moved.
    private static func snapshot() -> URL? {
        let fm = FileManager.default
        let source = databaseURL
        guard fm.isReadableFile(atPath: source.path) else { return nil }

        let destination = fm.temporaryDirectory
            .appendingPathComponent("mira-usernoted-\(getuid()).db")

        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            let to   = URL(fileURLWithPath: destination.path + suffix)
            guard fm.fileExists(atPath: from.path) else {
                try? fm.removeItem(at: to)
                continue
            }
            try? fm.removeItem(at: to)
            try? fm.copyItem(at: from, to: to)
        }
        return fm.fileExists(atPath: destination.path) ? destination : nil
    }

    static func modifiedAt() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date
    }

    /// Most recent deliveries, newest first.
    static func recent(limit: Int = 12) -> [SystemNotification] {
        guard let path = snapshot() else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT a.identifier, r.data, r.delivered_date
        FROM record r JOIN app a ON r.app_id = a.app_id
        ORDER BY r.delivered_date DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [SystemNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let identCString = sqlite3_column_text(stmt, 0) else { continue }
            let bundleID = String(cString: identCString)

            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 1))
            let data = Data(bytes: blob, count: length)

            // Core Data timestamps: seconds since 2001-01-01.
            let delivered = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))

            guard let parsed = parse(data, bundleID: bundleID, delivered: delivered) else { continue }
            out.append(parsed)
        }
        return out
    }

    /// The payload is a binary plist whose `req` dictionary holds the fields the
    /// banner would have shown: `titl`, `subt`, `body`.
    private static func parse(_ data: Data, bundleID: String, delivered: Date) -> SystemNotification? {
        guard let plist = try? PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any]
        else { return nil }

        let title    = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body     = request["body"] as? String ?? ""

        let message = [subtitle, body]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
            .replacingOccurrences(of: "\n", with: " ")

        guard !title.isEmpty || !message.isEmpty else { return nil }

        // Identity has to include the delivery time: the same sender sending two
        // messages produces the same app and title, and keying on those alone
        // would make the second one look like a duplicate of the first and never
        // pop.
        let id = "\(bundleID)|\(title)|\(message)|\(delivered.timeIntervalSince1970)"

        return SystemNotification(id: id,
                                  app: appName(for: bundleID),
                                  message: message.isEmpty ? title : message,
                                  title: title,
                                  bundleID: bundleID,
                                  deliveredAt: delivered)
    }

    /// Bundle id to something a person recognises. Falls back to the last path
    /// component, which is right often enough ("com.hnc.Discord" → "Discord").
    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        switch bundleID {
        case "com.apple.mobilesms":    return "Messages"
        case "com.apple.mobilemail":   return "Mail"
        case "com.apple.iCal":         return "Calendar"
        case "com.apple.reminders":    return "Reminders"
        case "com.apple.facetime":     return "FaceTime"
        case "com.apple.scripteditor2":return "Script Editor"
        default:
            return bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
        }
    }
}
