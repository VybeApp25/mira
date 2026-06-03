// MiraToolService.swift
// Tool definitions (sent to Realtime API) + local execution handlers.
// Tools: open_application, get_calendar_events, control_music, search_web, run_shortcut

import Foundation
import AppKit
import EventKit

enum MiraToolService {

    // MARK: - Schema (sent in session.update → tools array)

    static let definitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "get_current_context",
            "description": """
                Get the user's live Mac context: active app, browser URL, selected text, \
                clipboard contents, battery level, and current time. \
                Call this whenever you need to know what the user is looking at or working on, \
                before answering questions like "summarize this", "reply to this", or "what's open".
                """,
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": []
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "open_application",
            "description": "Open or switch to a macOS application by name.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app_name": [
                        "type": "string",
                        "description": "App name, e.g. 'Safari', 'Finder', 'Spotify', 'Calendar', 'Terminal'"
                    ]
                ],
                "required": ["app_name"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "get_calendar_events",
            "description": "Fetch the user's upcoming calendar events for today or the next N days.",
            "parameters": [
                "type": "object",
                "properties": [
                    "days_ahead": [
                        "type": "integer",
                        "description": "Days to look ahead (1–7, default 1 for today)"
                    ]
                ],
                "required": []
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "control_music",
            "description": "Control Apple Music playback.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["play", "pause", "toggle", "next", "previous"],
                        "description": "The playback action"
                    ]
                ],
                "required": ["action"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "search_web",
            "description": "Open a Google search in the default browser.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms"]
                ],
                "required": ["query"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "run_shortcut",
            "description": "Run a macOS Shortcut by its exact name.",
            "parameters": [
                "type": "object",
                "properties": [
                    "shortcut_name": [
                        "type": "string",
                        "description": "Exact Shortcut name as it appears in the Shortcuts app"
                    ]
                ],
                "required": ["shortcut_name"]
            ] as [String: Any]
        ],
    ]

    // MARK: - Execution router

    static func execute(name: String, argsJSON: String) async -> String {
        let args = parse(argsJSON)
        switch name {
        case "get_current_context": return await currentContext()
        case "open_application":    return openApplication(args)
        case "get_calendar_events": return await calendarEvents(args)
        case "control_music":       return musicControl(args)
        case "search_web":          return searchWeb(args)
        case "run_shortcut":        return runShortcut(args)
        default:                    return "Unknown tool: \(name)"
        }
    }

    private static func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - get_current_context

    private static func currentContext() async -> String {
        await MainActor.run { ContextService.shared.buildPromptBlock(max: 1000) }
    }

    // MARK: - open_application

    private static func openApplication(_ args: [String: Any]) -> String {
        guard let name = args["app_name"] as? String else { return "Missing app_name." }
        let ws = NSWorkspace.shared
        // Activate if already running
        if let app = ws.runningApplications
            .first(where: { $0.localizedName?.lowercased() == name.lowercased() }) {
            app.activate()
            return "Switched to \(app.localizedName ?? name)."
        }
        // Try /Applications/<Name>.app
        let candidates = [
            "/Applications/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
            "/System/Applications/\(name).app",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                ws.openApplication(at: url, configuration: .init()) { _, _ in }
                return "Opened \(name)."
            }
        }
        return "Could not open \(name). Check the app name and that it's installed."
    }

    // MARK: - get_calendar_events

    private static func calendarEvents(_ args: [String: Any]) async -> String {
        let days   = min(max(args["days_ahead"] as? Int ?? 1, 1), 7)
        let store  = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        // rawValue 3 = .fullAccess (macOS 14+) / .authorized (macOS 13)
        guard status.rawValue == 3 else {
            return "Calendar access not granted. Enable it in System Settings › Privacy › Calendars."
        }
        let cal   = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: days, to: start) else {
            return "Could not compute date range."
        }
        let events = store.events(
            matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)
        ).sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return "No events in the next \(days) day(s)." }
        return events.prefix(8).map { e in
            let time = e.isAllDay
                ? "all day"
                : e.startDate.formatted(.dateTime.hour().minute())
            return "• \(e.title ?? "Untitled") — \(time)"
        }.joined(separator: "\n")
    }

    // MARK: - control_music (Apple Music via AppleScript)

    private static func musicControl(_ args: [String: Any]) -> String {
        guard let action = args["action"] as? String else { return "Missing action." }
        let script: String
        switch action {
        case "play":     script = "tell application \"Music\" to play"
        case "pause":    script = "tell application \"Music\" to pause"
        case "toggle":   script = "tell application \"Music\" to playpause"
        case "next":     script = "tell application \"Music\" to next track"
        case "previous": script = "tell application \"Music\" to previous track"
        default: return "Unknown music action '\(action)'."
        }
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil ? "Done." : "Music control failed — is Apple Music open?"
    }

    // MARK: - search_web

    private static func searchWeb(_ args: [String: Any]) -> String {
        guard let query   = args["query"] as? String,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url     = URL(string: "https://www.google.com/search?q=\(encoded)") else {
            return "Invalid query."
        }
        NSWorkspace.shared.open(url)
        return "Opened search for '\(query)' in your browser."
    }

    // MARK: - run_shortcut

    private static func runShortcut(_ args: [String: Any]) -> String {
        guard let name    = args["shortcut_name"] as? String,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url     = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
            return "Invalid shortcut name."
        }
        NSWorkspace.shared.open(url)
        return "Running shortcut '\(name)'."
    }
}
