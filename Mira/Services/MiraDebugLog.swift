import Foundation

// MARK: - MiraDebugLog
//
// Lightweight file logger that appends to /tmp/mira_debug.log. Exists because
// unified-logging (os_log / NSLog) can't always be read back from a sandboxed
// tooling session, whereas a plain file in /tmp can. Use for diagnosing runtime
// behavior we can't observe interactively (drag-and-drop, menu-bar clipping, …).
// Cheap and synchronous — intended for low-frequency debug events, not hot paths.
//
// DEBUG-ONLY: the body compiles out of Release builds so shipped app never writes
// to /tmp. `log(_:)` stays defined in all configs (a no-op in Release) so call
// sites need no #if guards. Local Debug builds still log as before.

enum MiraDebugLog {
    #if DEBUG
    static let path = "/tmp/mira_debug.log"
    private static let queue = DispatchQueue(label: "com.trevonbarbour.mira.debuglog")
    #endif

    static func log(_ message: String) {
        #if DEBUG
        let line = "\(Self.stamp()) \(message)\n"
        // Mirror to the normal console too so it's visible either way.
        NSLog("%@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }

    #if DEBUG
    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    #endif
}
