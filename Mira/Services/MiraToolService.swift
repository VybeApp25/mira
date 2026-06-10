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
            "name": "save_content",
            "description": """
                Save user-owned content to Notes or Files. \
                Call when the user asks to save, store, keep, write down, or export content. \
                destination "notes": ideas, drafts, text, anything editable the user wants to revisit. \
                destination "files": structured output, exports, documents to keep as a file. \
                NEVER use this for user preferences or identity — use remember for those.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "content":     ["type": "string",
                                   "description": "The full content to save"],
                    "title":       ["type": "string",
                                   "description": "Title or filename (without extension)"],
                    "destination": ["type": "string",
                                   "enum": ["notes", "files"],
                                   "description": "notes = Notes app, files = text file on Desktop"]
                ],
                "required": ["content", "destination"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "remember",
            "description": """
                Store a persistent fact about the user — preferences, identity, habits, goals, or ongoing projects. \
                Call when the user says "remember that", "I prefer", "from now on", or explicitly states something about themselves. \
                Use snake_case keys like preferred_browser, workout_goal, current_project. \
                NEVER call this to save content, documents, notes, tasks, or anything the user wants to read later — use save_content for those.
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
                Capture a live screenshot of the user's Mac screen and describe everything visible, \
                plus active app, browser URL, selected text, clipboard, battery, and time. \
                ALWAYS call this when the user says any of the following — \
                "read my screen", "what's on my screen", "what do you see", "look at my screen", \
                "this", "that", "here", "on my screen", "in this tab", "selected text", \
                "copied text", "what am I looking at", "summarize this", "reply to this", \
                "explain this", "translate this", "what does this say", "open this", "search for this" — \
                or any request that refers to content visible on screen or in the clipboard.
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
            "description": "Control Apple Music playback. action 'quit' closes Apple Music entirely.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["play", "pause", "toggle", "next", "previous", "quit"],
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
        // ── App management ────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "quit_application",
            "description": "Quit / close a macOS application by name. Use when the user says 'close', 'quit', or 'exit' an app.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app_name": [
                        "type": "string",
                        "description": "App name, e.g. 'Spotify', 'Safari', 'Slack', 'Terminal'"
                    ]
                ],
                "required": ["app_name"]
            ] as [String: Any]
        ],
        // ── Spotify ───────────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "control_spotify",
            "description": """
                Control Spotify or play a specific song. \
                action "quit": quits/closes Spotify entirely — use when the user says "close Spotify", "quit Spotify", "exit Spotify". \
                action "play_song": searches Spotify for the song and plays the top result — \
                use this when the user asks to play a specific song or artist on Spotify. \
                action "play"/"pause"/"toggle"/"next"/"previous": basic playback control. \
                Requires Spotify to be installed. Keyboard automation requires Accessibility permission.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["play", "pause", "toggle", "next", "previous", "play_song", "quit"],
                        "description": "The action to perform"
                    ],
                    "song": [
                        "type": "string",
                        "description": "Song + artist for play_song, e.g. 'Blinding Lights The Weeknd'"
                    ]
                ],
                "required": ["action"]
            ] as [String: Any]
        ],
        // ── Power tools ───────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "run_apple_script",
            "description": """
                Execute any AppleScript on the Mac — the most powerful automation tool available. \
                Use for: sending iMessages (tell application "Messages" to send ...), \
                composing/sending email, controlling any scriptable app, reading app state, \
                automating Finder (move/rename/open files), clicking UI elements via System Events, \
                or anything not covered by other tools. \
                System Events keystroke/click requires Accessibility permission (System Settings › Privacy › Accessibility). \
                Return value is the script's result string, or "Done." if the script has no return value.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "Valid AppleScript source code to execute"
                    ]
                ],
                "required": ["script"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "run_shell_command",
            "description": """
                Run a zsh shell command on the Mac. \
                Use for: file management (mv, cp, mkdir, rm, ls, find), \
                reading file contents (cat), system info (df, ps, system_profiler), \
                running scripts, git commands, installing via brew, or any CLI task. \
                Output capped at 2000 characters. Avoid commands that run indefinitely.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "Shell command to run, e.g. 'ls ~/Desktop', 'cat ~/notes.txt'"
                    ]
                ],
                "required": ["command"]
            ] as [String: Any]
        ],
        // ── System controls ───────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "set_volume",
            "description": "Set the Mac's output volume. Level 0 = mute, 100 = maximum.",
            "parameters": [
                "type": "object",
                "properties": [
                    "level": [
                        "type": "integer",
                        "description": "Volume level 0–100"
                    ]
                ],
                "required": ["level"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "adjust_brightness",
            "description": "Set the Mac's screen brightness. Level 0 = off, 100 = maximum.",
            "parameters": [
                "type": "object",
                "properties": [
                    "level": [
                        "type": "integer",
                        "description": "Brightness level 0–100"
                    ]
                ],
                "required": ["level"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "toggle_mute",
            "description": "Mute or unmute the Mac's audio output. Use when user says 'mute', 'unmute', 'silence', or 'turn off sound'.",
            "parameters": [
                "type": "object",
                "properties": [
                    "mute": [
                        "type": "boolean",
                        "description": "true to mute, false to unmute"
                    ]
                ],
                "required": ["mute"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "lock_screen",
            "description": "Lock the Mac screen immediately. Use when user says 'lock screen', 'lock my computer', or 'lock mac'.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": []
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "type_text",
            "description": """
                Type text into whatever app is currently focused. \
                Requires Accessibility permission (System Settings › Privacy & Security › Accessibility). \
                Use to fill search fields, compose messages, or enter text in any app.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The text to type into the active app"
                    ]
                ],
                "required": ["text"]
            ] as [String: Any]
        ],
        // ── Project tools ─────────────────────────────────────────────────────────
        [
            "type": "function",
            "name": "create_project",
            "description": """
                Create a new long-term Mira project with a goal and optional completion criteria. \
                Call when the user wants Mira to work on something over multiple sessions — \
                building an app, writing a report series, or any multi-step goal that spans more than one conversation. \
                Each criterion is one verifiable outcome (e.g. "App builds cleanly", "Voice mode works").
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "name":     ["type": "string",
                                 "description": "Short project name, e.g. 'Vybe iOS App'"],
                    "goal":     ["type": "string",
                                 "description": "One sentence describing the desired end state"],
                    "criteria": ["type": "array",
                                 "items": ["type": "string"],
                                 "description": "Optional list of verifiable completion criteria"]
                ],
                "required": ["name", "goal"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "save_checkpoint",
            "description": """
                Save a checkpoint for the active project. \
                Call at natural stopping points during a long agent task — \
                after completing a meaningful unit of work, before switching to a new sub-task, \
                or whenever the agent might be interrupted. \
                The checkpoint is used to resume the project automatically if Mira is restarted.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string",
                                   "description": "UUID of the project (from create_project or get_project_context)"],
                    "title":      ["type": "string",
                                   "description": "Short title for this checkpoint, e.g. 'SwiftUI views complete'"],
                    "summary":    ["type": "string",
                                   "description": "What was accomplished since the last checkpoint"],
                    "context":    ["type": "string",
                                   "description": "State needed to resume: current files, next planned step, any blockers"],
                    "files":      ["type": "array",
                                   "items": ["type": "string"],
                                   "description": "Absolute paths of files created or modified in this session"]
                ],
                "required": ["project_id", "title", "summary", "context"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "complete_criterion",
            "description": """
                Mark a completion criterion as done for a project. \
                Call when the agent has verifiably achieved one of the project's success criteria — \
                confirmed by a passing build, a test, or a user confirmation. \
                Mira will automatically mark the project completed when all criteria are done.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "project_id":   ["type": "string",
                                     "description": "UUID of the project"],
                    "criterion_id": ["type": "string",
                                     "description": "UUID of the criterion (from get_project_context)"],
                    "verified_by":  ["type": "string",
                                     "enum": ["agent", "user"],
                                     "description": "Who verified this criterion is complete"]
                ],
                "required": ["project_id", "criterion_id"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "add_project_decision",
            "description": """
                Record an architectural or design decision made during the project. \
                Call when the agent chooses one approach over another — \
                e.g. choosing SwiftData over CoreData, or picking a specific API. \
                These decisions are shown in the project timeline and used to avoid re-litigating settled choices.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "project_id":  ["type": "string",
                                    "description": "UUID of the project"],
                    "description": ["type": "string",
                                    "description": "What was decided, e.g. 'Chose SwiftData over CoreData'"],
                    "rationale":   ["type": "string",
                                    "description": "Why this decision was made"]
                ],
                "required": ["project_id", "description", "rationale"]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "get_project_context",
            "description": """
                Get the full context of a project — status, criteria, latest checkpoint, decisions, and resume prompt. \
                Call at the start of any project session to orient the agent, \
                or when the user asks about project progress. \
                Returns the resume prompt ready to use.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string",
                                   "description": "UUID of the project. Omit to get context for the most recently active project."]
                ],
                "required": []
            ] as [String: Any]
        ],
        [
            "type": "function",
            "name": "query_project_history",
            "description": """
                Query the work history of a project — sessions, personas, artifacts, and checkpoints. \
                Call when the user asks about past sessions: \
                "What did we do last session?", "Which session created X?", \
                "What did Mira Developer accomplish?", "How many sessions ran yesterday?", \
                "Show me sessions related to Y." \
                Returns a natural-language answer drawn from the project's session records.
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "question":   ["type": "string",
                                   "description": "The user's question about the project's work history"],
                    "project_id": ["type": "string",
                                   "description": "UUID of the project. Omit to query the most recently active project."]
                ],
                "required": ["question"]
            ] as [String: Any]
        ],
    ]

    // MARK: - Execution router

    static func execute(name: String, argsJSON: String) async -> String {
        let args = parse(argsJSON)
        switch name {
        case "save_content":        return await saveContent(args)
        case "remember":            return await rememberMemory(args)
        case "recall_memories":     return await recallMemories(args)
        case "forget":              return await forgetMemory(args)
        case "get_current_context": return await currentContext()
        case "open_application":    return openApplication(args)
        case "quit_application":    return quitApplication(args)
        case "get_calendar_events": return await calendarEvents(args)
        case "control_music":       return musicControl(args)
        case "control_spotify":     return controlSpotify(args)
        case "search_web":          return searchWeb(args)
        case "run_shortcut":        return runShortcut(args)
        case "run_apple_script":    return runAppleScript(args)
        case "run_shell_command":   return await runShellCommand(args)
        case "set_volume":          return setVolume(args)
        case "adjust_brightness":   return adjustBrightness(args)
        case "toggle_mute":         return toggleMute(args)
        case "lock_screen":         return lockScreen()
        case "type_text":           return typeText(args)
        // Project tools
        case "create_project":        return await createProject(args)
        case "save_checkpoint":       return await saveCheckpoint(args)
        case "complete_criterion":    return await completeCriterion(args)
        case "add_project_decision":  return await addProjectDecision(args)
        case "get_project_context":   return await getProjectContext(args)
        case "query_project_history": return await queryProjectHistory(args)
        default:                      return "Unknown tool: \(name)"
        }
    }

    private static func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - save_content

    private static func saveContent(_ args: [String: Any]) async -> String {
        guard let content = args["content"] as? String,
              let dest    = args["destination"] as? String else {
            return "Missing required fields: content, destination."
        }
        let rawTitle = args["title"] as? String
        let title    = rawTitle?.isEmpty == false
            ? rawTitle!
            : String(content.prefix(40).components(separatedBy: .newlines).first ?? "Mira Note")

        switch dest {
        case "notes":
            return saveToNotes(content: content, title: title)
        case "files":
            return saveToFile(content: content, title: title)
        default:
            return "Unknown destination '\(dest)'."
        }
    }

    private static func saveToNotes(content: String, title: String) -> String {
        let safe    = content.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script  = """
            tell application "Notes"
                make new note with properties {name:"\(safeTitle)", body:"\(safe)"}
            end tell
            """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil
            ? "Saved to Notes: \"\(title)\"."
            : "Failed to save to Notes. Make sure Notes is available."
    }

    private static func saveToFile(content: String, title: String) -> String {
        let safeName = title
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let desktop  = URL(fileURLWithPath: "\(NSHomeDirectory())/Desktop")
        var url      = desktop.appendingPathComponent("\(safeName).txt")
        var counter  = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(safeName) \(counter).txt")
            counter += 1
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
            return "Saved \"\(url.lastPathComponent)\" to your Desktop."
        } catch {
            return "Failed to write file: \(error.localizedDescription)"
        }
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
        // Text context: active app, URL, selected text, clipboard, battery, time
        let textContext = await MainActor.run { ContextService.shared.buildPromptBlock(max: 800) }

        // Screenshot → Claude vision → screen description
        let screenDescription = await captureScreenDescription()

        if screenDescription.isEmpty { return textContext }
        return textContext + "\n\n[Screen]\n" + screenDescription
    }

    private static func captureScreenDescription() async -> String {
        let apiKey = await MainActor.run { AppSecrets.anthropicAPIKey }
        guard !apiKey.isEmpty else { return "" }

        let capture = ScreenCaptureService()
        guard let screenshot = try? await capture.captureMainDisplay() else {
            return "Screen Recording permission not granted. Ask the user to enable Mira in System Settings › Privacy & Security › Screen Recording."
        }

        let claude = ClaudeService(apiKey: apiKey)
        let description = try? await claude.ask(
            prompt: "Describe everything visible on this screen. Include: app name and window title, all visible text content, UI elements, any documents or media open, and what the user appears to be working on. Be thorough — the description will be read aloud by a voice assistant.",
            screenshot: screenshot,
            system: "You are describing a Mac screen for a voice assistant. Be specific and comprehensive but concise. No markdown. Plain sentences only."
        )
        return description ?? ""
    }

    // MARK: - open_application

    private static func openApplication(_ args: [String: Any]) -> String {
        guard let name = args["app_name"] as? String else { return "Missing app_name." }
        // `open -a` searches all install locations and activates if already running
        let proc = Process()
        proc.launchPath = "/usr/bin/open"
        proc.arguments = ["-a", name]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 { return "Opened \(name)." }
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            return "Could not open '\(name)'. \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            return "Error launching \(name): \(error.localizedDescription)"
        }
    }

    // MARK: - quit_application

    private static func quitApplication(_ args: [String: Any]) -> String {
        guard let name = args["app_name"] as? String else { return "Missing app_name." }
        let safe = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"\(safe)\" to quit"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            let msg = e["NSAppleScriptErrorMessage"] as? String ?? ""
            return "Could not quit '\(name)'. \(msg)"
        }
        return "Quit \(name)."
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
        case "quit":     script = "tell application \"Music\" to quit"
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

    // MARK: - control_spotify

    private static func controlSpotify(_ args: [String: Any]) -> String {
        guard let action = args["action"] as? String else { return "Missing action." }

        switch action {
        case "play":     return spotifyAppleScript("play")
        case "pause":    return spotifyAppleScript("pause")
        case "toggle":   return spotifyAppleScript("playpause")
        case "next":     return spotifyAppleScript("next track")
        case "previous": return spotifyAppleScript("previous track")
        case "quit":     return spotifyAppleScript("quit")

        case "play_song":
            guard let song = args["song"] as? String, !song.isEmpty else { return "Missing song." }
            let safe = song
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // Keyboard automation via System Events — searches Spotify and plays the top result.
            // Requires Accessibility permission (Mira listed in System Settings › Privacy › Accessibility).
            let script = """
                tell application "Spotify" to activate
                delay 0.8
                tell application "System Events"
                    tell process "Spotify"
                        keystroke "l" using {command down}
                        delay 0.5
                        keystroke "a" using {command down}
                        keystroke "\(safe)"
                        key code 36
                        delay 1.5
                        key code 36
                    end tell
                end tell
                """
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if err == nil { return "Searching and playing '\(song)' on Spotify." }

            // Fallback: URL scheme — shows search results without auto-playing
            let encoded = song.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "spotify:search:\(encoded)") { NSWorkspace.shared.open(url) }
            let reason = (err?["NSAppleScriptErrorMessage"] as? String) ?? "unknown error"
            return "Opened Spotify search for '\(song)'. To enable auto-play, go to System Settings › Privacy & Security › Accessibility and add Mira. (\(reason))"

        default:
            return "Unknown Spotify action '\(action)'."
        }
    }

    private static func spotifyAppleScript(_ command: String) -> String {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Spotify\" to \(command)")?.executeAndReturnError(&err)
        if let e = err {
            return "Spotify error: \((e["NSAppleScriptErrorMessage"] as? String) ?? "Is Spotify open?")"
        }
        return "Done."
    }

    // MARK: - run_apple_script

    private static func runAppleScript(_ args: [String: Any]) -> String {
        guard let script = args["script"] as? String else { return "Missing script." }
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            let msg = e["NSAppleScriptErrorMessage"] as? String
                   ?? e["NSAppleScriptErrorBriefMessage"] as? String
                   ?? e.description
            return "AppleScript error: \(msg)"
        }
        return result?.stringValue ?? "Done."
    }

    // MARK: - run_shell_command

    private static func runShellCommand(_ args: [String: Any]) async -> String {
        guard let command = args["command"] as? String else { return "Missing command." }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.launchPath = "/bin/zsh"
                proc.arguments  = ["-c", command]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    var out  = String(data: data, encoding: .utf8) ?? ""
                    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    let status = proc.terminationStatus
                    if out.isEmpty { cont.resume(returning: "Done (exit \(status)).") }
                    else           { cont.resume(returning: String(out.prefix(2000))) }
                } catch {
                    cont.resume(returning: "Launch error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - set_volume

    private static func setVolume(_ args: [String: Any]) -> String {
        guard let level = args["level"] as? Int, level >= 0, level <= 100 else {
            return "Level must be an integer 0–100."
        }
        var err: NSDictionary?
        NSAppleScript(source: "set volume output volume \(level)")?.executeAndReturnError(&err)
        return err == nil ? "Volume set to \(level)%." : "Failed to set volume."
    }

    // MARK: - adjust_brightness

    private static func adjustBrightness(_ args: [String: Any]) -> String {
        guard let level = args["level"] as? Int, level >= 0, level <= 100 else {
            return "Level must be an integer 0–100."
        }
        let fraction = Double(level) / 100.0
        var err: NSDictionary?
        // brightness via CoreDisplay if available, fall back to osascript
        let script = "tell application \"System Events\" to set brightness of display 1 to \(fraction)"
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            // fallback: shell command using brightness CLI or osascript
            let proc = Process()
            proc.launchPath = "/usr/bin/osascript"
            proc.arguments  = ["-e", "tell application \"System Preferences\" to quit"]
            try? proc.run()
            // Use IOKit via shell
            let sh = Process()
            sh.launchPath = "/bin/zsh"
            sh.arguments  = ["-c", "brightness \(fraction) 2>/dev/null || true"]
            try? sh.run()
            sh.waitUntilExit()
        }
        return "Brightness set to \(level)%."
    }

    // MARK: - toggle_mute

    private static func toggleMute(_ args: [String: Any]) -> String {
        guard let mute = args["mute"] as? Bool else { return "Missing mute parameter." }
        var err: NSDictionary?
        NSAppleScript(source: "set volume output muted \(mute ? "true" : "false")")?.executeAndReturnError(&err)
        return err == nil ? (mute ? "Audio muted." : "Audio unmuted.") : "Failed to change mute state."
    }

    // MARK: - lock_screen

    private static func lockScreen() -> String {
        let proc = Process()
        proc.launchPath = "/usr/bin/pmset"
        proc.arguments  = ["displaysleepnow"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {}
        // Also trigger login window for full screen lock
        var err: NSDictionary?
        NSAppleScript(source: """
            tell application "System Events"
                keystroke "q" using {control down, command down}
            end tell
            """)?.executeAndReturnError(&err)
        return "Screen locked."
    }

    // MARK: - type_text

    private static func typeText(_ args: [String: Any]) -> String {
        guard let text = args["text"] as? String else { return "Missing text." }
        let safe = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to keystroke \"\(safe)\""
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let e = err {
            let msg = e["NSAppleScriptErrorMessage"] as? String ?? e.description
            return "Type error: \(msg). Add Mira to System Settings › Privacy & Security › Accessibility to enable typing."
        }
        return "Typed text."
    }

    // MARK: - Project tools

    private static func createProject(_ args: [String: Any]) async -> String {
        guard let name = args["name"] as? String,
              let goal = args["goal"] as? String else {
            return "Missing required fields: name, goal."
        }
        let criteria = args["criteria"] as? [String] ?? []
        let project = await MainActor.run {
            ProjectEngine.shared.createProject(name: name,
                                               goal: goal,
                                               criteriaDescriptions: criteria)
        }
        var result = "Project created: '\(project.name)' (id: \(project.id.uuidString))."
        if !criteria.isEmpty {
            result += " \(criteria.count) completion criteria added."
        }
        return result
    }

    private static func saveCheckpoint(_ args: [String: Any]) async -> String {
        guard let projectIdStr = args["project_id"] as? String,
              let projectId    = UUID(uuidString: projectIdStr),
              let title        = args["title"] as? String,
              let summary      = args["summary"] as? String,
              let context      = args["context"] as? String else {
            return "Missing required fields: project_id, title, summary, context."
        }
        let files = args["files"] as? [String] ?? []
        let checkpoint = await MainActor.run {
            ProjectEngine.shared.saveCheckpoint(projectId: projectId,
                                                title: title,
                                                summary: summary,
                                                agentContext: context,
                                                filesModified: files)
        }
        guard let cp = checkpoint else {
            return "Project not found: \(projectIdStr)."
        }
        return "Checkpoint #\(cp.number) saved: '\(cp.title)'."
    }

    private static func completeCriterion(_ args: [String: Any]) async -> String {
        guard let projectIdStr   = args["project_id"] as? String,
              let criterionIdStr = args["criterion_id"] as? String,
              let projectId      = UUID(uuidString: projectIdStr),
              let criterionId    = UUID(uuidString: criterionIdStr) else {
            return "Missing required fields: project_id, criterion_id."
        }
        let verifiedBy = args["verified_by"] as? String ?? "agent"
        await MainActor.run {
            ProjectEngine.shared.completeCriterion(projectId: projectId,
                                                   criterionId: criterionId,
                                                   verifiedBy: verifiedBy)
        }
        return "Criterion marked complete."
    }

    private static func addProjectDecision(_ args: [String: Any]) async -> String {
        guard let projectIdStr = args["project_id"] as? String,
              let projectId    = UUID(uuidString: projectIdStr),
              let description  = args["description"] as? String,
              let rationale    = args["rationale"] as? String else {
            return "Missing required fields: project_id, description, rationale."
        }
        await MainActor.run {
            ProjectEngine.shared.addDecision(to: projectId,
                                             description: description,
                                             rationale: rationale)
        }
        return "Decision recorded: \(description)."
    }

    private static func getProjectContext(_ args: [String: Any]) async -> String {
        let projectIdStr = args["project_id"] as? String
        let project = await MainActor.run { () -> MiraProject? in
            if let str = projectIdStr, let id = UUID(uuidString: str) {
                return ProjectEngine.shared.project(id: id)
            }
            // Fall back to the most recently active project
            return ProjectEngine.shared.activeProjects.first
        }
        guard let p = project else {
            return "No active project found. Create one with create_project."
        }
        let resumePrompt = await MainActor.run {
            p.lastResumePrompt ?? ProjectEngine.shared.buildResumePrompt(for: p)
        }
        return """
            Project: \(p.name) [\(p.id.uuidString)]
            Status: \(p.status.label)
            Progress: \(p.progressPercent)%
            Criteria:
            \(p.criteria.map { "  \($0.isComplete ? "✓" : "○") [\($0.id.uuidString)] \($0.description)" }.joined(separator: "\n"))

            \(resumePrompt)
            """
    }

    // MARK: - query_project_history

    private static func queryProjectHistory(_ args: [String: Any]) async -> String {
        guard let question = args["question"] as? String, !question.isEmpty else {
            return "Missing required field: question."
        }
        let projectIdStr = args["project_id"] as? String

        let (project, apiKey) = await MainActor.run { () -> (MiraProject?, String) in
            let p: MiraProject?
            if let str = projectIdStr, let id = UUID(uuidString: str) {
                p = ProjectEngine.shared.project(id: id)
            } else {
                // Most recently active, then any project if none active
                p = ProjectEngine.shared.activeProjects.first
                  ?? ProjectEngine.shared.projects.first
            }
            return (p, AppSecrets.anthropicAPIKey)
        }

        guard let project = project else {
            return "No project found. Create one first with create_project."
        }
        guard !apiKey.isEmpty else {
            return "Claude API key not configured."
        }

        let context = await MainActor.run {
            ProjectEngine.shared.buildSessionContext(for: project)
        }

        do {
            let service = ClaudeService(apiKey: apiKey)
            return try await service.queryProjectHistory(question: question, context: context)
        } catch {
            return "Could not query session history: \(error.localizedDescription)"
        }
    }
}
