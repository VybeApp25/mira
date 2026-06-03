// MiraToolService.swift
// Tool definitions (sent to Realtime API) + local execution handlers.
// Tools: open_application, get_calendar_events, control_music, search_web, run_shortcut

import Foundation
import AppKit
import EventKit

enum MiraToolService {

    // MARK: - Schema (sent in session.update → tools array)

    static let definitions: [[String: Any]] = [
        // ── Memory tools ──────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "remember",
            "description": """
                Store or update something about the user in long-term memory. \
                Call this proactively when the user states a preference ("I use Safari"), \
                shares a personal fact ("I'm training for a marathon"), \
                mentions an ongoing project ("I'm building a workout app"), \
                reveals a goal ("I want to hit 200 push-ups"), or names a person they mention often. \
                Use snake_case keys like preferred_browser, current_project, workout_goal.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "key":      ["type": "string",
                                 "description": "Short snake_case identifier, e.g. preferred_browser"],
                    "value":    ["type": "string",
                                 "description": "The value to store, e.g. Safari"],
                    "category": ["type": "string",
                                 "enum": ["preference", "project", "person", "fact", "goal"],
                                 "description": "Memory category"],
                    "notes":    ["type": "string",
                                 "description": "Optional supporting context or reason"]
                ],
                "required": ["key", "value", "category"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "recall_memories",
            "description": """
                Search long-term memory for what Mira knows about the user. \
                Call this before answering personalised questions, recommending apps/services, \
                or when the user asks "do you remember" or "what do you know about me".
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Search term, e.g. browser, project, music"]
                ],
                "required": ["query"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "forget",
            "description": "Delete a memory by key. Use when the user says 'forget that' or corrects an outdated preference.",
            "parameters": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "The memory key to delete"]
                ],
                "required": ["key"]
            ] as [String: Any]
        ],
        // ── Context tool ──────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "get_current_context",
            "description": """
                Get the user's live Mac context: active app, browser URL, selected text, \
                clipboard contents, battery level, and current time. \
                Call this when the user says any of the following — \
                "this", "that", "here", "on my screen", "in this tab", "selected text", \
                "copied text", "what am I looking at", "what's on my screen", \
                "summarize this", "reply to this", "explain this", "translate this", \
                "what does this say", "open this", "search for this" — \
                or any request that refers to content visible on screen or in the clipboard \
                without explicitly stating what that content is.
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
        case "remember":            return await rememberMemory(args)
        case "recall_memories":     return await recallMemories(args)
        case "forget":              return await forgetMemory(args)
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

    // MARK: - Memory tools

    private static func rememberMemory(_ args: [String: Any]) async -> String {
        guard let key   = args["key"]   as? String,
              let value = args["value"] as? String,
              let catRaw = args["category"] as? String,
              let cat   = Memory.Category(rawValue: catRaw) else {
            return "Missing required fields: key, value, category."
        }
        let notes = args["notes"] as? String
        await MainActor.run {
            MemoryStore.shared.upsert(key: key, value: value,
                                      category: cat, source: .explicit,
                                      confidence: 0.95, notes: notes)
        }
        return "Remembered: \(key) = \(value)."
    }

    private static func recallMemories(_ args: [String: Any]) async -> String {
        let query = args["query"] as? String ?? ""
        let results = await MainActor.run { MemoryStore.shared.recall(query: query) }
        guard !results.isEmpty else { return "No memories found for '\(query)'." }
        return results.prefix(8).map { "• \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func forgetMemory(_ args: [String: Any]) async -> String {
        guard let key = args["key"] as? String else { return "Missing key." }
        await MainActor.run { MemoryStore.shared.delete(key: key) }
        return "Forgotten: \(key)."
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
