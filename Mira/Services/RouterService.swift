import Foundation
import AppKit
import CoreGraphics

// MARK: - Route enum

enum MiraRoute: String, CaseIterable {
    case localResponse          = "local_response"
    case screenGuidance         = "screen_guidance"
    case agentTask              = "agent_task"
    case websiteBuilder         = "website_builder"
    case spotifyControl         = "spotify_control"
    case openURL                = "open_url"
    case memoryQuery            = "memory_query"
    case memoryWrite            = "memory_write"
    case fileOperation          = "file_operation"
    case calendarAction         = "calendar_action"
    case notesAction            = "notes_action"
    case composioAction         = "composio_action"
    case clarificationRequired  = "clarification_required"
    case confirmationRequired   = "confirmation_required"
    case permissionRequired     = "permission_required"
    case higherModel            = "higher_model"

    var displayName: String {
        switch self {
        case .localResponse:          return "Local"
        case .screenGuidance:         return "Screen"
        case .agentTask:              return "Agent"
        case .websiteBuilder:         return "Website Builder"
        case .spotifyControl:         return "Spotify"
        case .openURL:                return "Open URL"
        case .memoryQuery:            return "Memory"
        case .memoryWrite:            return "Remember"
        case .fileOperation:          return "Files"
        case .calendarAction:         return "Calendar"
        case .notesAction:            return "Notes"
        case .composioAction:         return "Integration"
        case .clarificationRequired:  return "Clarify"
        case .confirmationRequired:   return "Confirm"
        case .permissionRequired:     return "Permission"
        case .higherModel:            return "Claude"
        }
    }
}

// MARK: - Clarification types

struct ClarificationStep: Identifiable {
    let id          = UUID()
    let question:    String
    let key:         String
    let options:    [String]?
    var placeholder: String?  = nil
    var isOptional:  Bool     = false
}

struct ClarificationSpec {
    let intent:  MiraRoute
    let opening: String
    let steps:   [ClarificationStep]
    var answers: [String: String] = [:]

    var isComplete: Bool {
        steps.filter { !$0.isOptional }.allSatisfy { answers[$0.key] != nil }
    }

    func assembledPrompt() -> String {
        switch intent {
        case .websiteBuilder:
            let type  = answers["type"]  ?? "business"
            let name  = answers["name"]  ?? ""
            let goal  = answers["goal"]  ?? "generate leads"
            let style = answers["style"] ?? "modern"
            let namePart = name.isEmpty ? "" : " for \(name)"
            return "Build a \(style.lowercased()) \(type.lowercased()) website\(namePart). Primary goal: \(goal.lowercased())."
        default:
            return answers.values.joined(separator: ". ")
        }
    }

    static func websiteBuilder() -> ClarificationSpec {
        ClarificationSpec(
            intent:  .websiteBuilder,
            opening: "I can build that — I just need a few details.",
            steps: [
                ClarificationStep(
                    question: "What kind of website?", key: "type",
                    options: ["SaaS", "Agency", "Ecommerce", "Local Business", "Portfolio", "Custom"]
                ),
                ClarificationStep(
                    question: "Business name?", key: "name",
                    options: nil, placeholder: "e.g. Atlanta Roofing", isOptional: true
                ),
                ClarificationStep(
                    question: "Primary goal?", key: "goal",
                    options: ["Get leads", "Drive sales", "Take bookings", "Share information"]
                ),
                ClarificationStep(
                    question: "Style?", key: "style",
                    options: ["Modern", "Luxury", "Corporate", "Minimal", "Creative"]
                )
            ]
        )
    }
}

// MARK: - Supporting types

struct RouterContext {
    var recentMessageCount: Int = 0
    var activeApp: String?      = nil
}

struct RouteDecision {
    let route: MiraRoute
    let confidence: Double
    let explanation: String
    var clarificationQuestion: String?  = nil
    var clarificationSpec: ClarificationSpec? = nil
    var confirmationSummary: String?    = nil
    var permissionNeeded: String?       = nil
    var isDangerous: Bool               = false
}

struct RouteResult {
    let route: MiraRoute
    let reply: String?
    let pendingConfirmation: PendingAction?
    let clarificationQuestion: String?
    let permissionNeeded: String?
    var guidanceTarget:     GuidanceTarget?     = nil
    var clarificationSpec:  ClarificationSpec?  = nil
    var missingPermission:  MiraPermission?     = nil   // typed permission for recovery card

    static func clarify(_ q: String) -> RouteResult {
        RouteResult(route: .clarificationRequired, reply: nil,
                    pendingConfirmation: nil, clarificationQuestion: q, permissionNeeded: nil)
    }
    static func clarifyWith(spec: ClarificationSpec) -> RouteResult {
        RouteResult(route: .clarificationRequired, reply: spec.opening,
                    pendingConfirmation: nil, clarificationQuestion: nil, permissionNeeded: nil,
                    guidanceTarget: nil, clarificationSpec: spec)
    }
    static func confirm(_ a: PendingAction) -> RouteResult {
        RouteResult(route: .confirmationRequired, reply: nil,
                    pendingConfirmation: a, clarificationQuestion: nil, permissionNeeded: nil)
    }
    static func permission(_ text: String, for perm: MiraPermission? = nil) -> RouteResult {
        RouteResult(route: .permissionRequired, reply: nil,
                    pendingConfirmation: nil, clarificationQuestion: nil, permissionNeeded: text,
                    missingPermission: perm)
    }
    static func reply(_ text: String, route: MiraRoute) -> RouteResult {
        RouteResult(route: route, reply: text,
                    pendingConfirmation: nil, clarificationQuestion: nil, permissionNeeded: nil)
    }
}

struct RouteLogEntry: Identifiable {
    let id          = UUID()
    let timestamp   = Date()
    let input:      String
    let route:      MiraRoute
    let confidence: Double
}

// MARK: - RouterService

@MainActor
final class RouterService: ObservableObject {
    static let shared = RouterService()
    private init() {}

    @Published private(set) var recentLog: [RouteLogEntry] = []
    private let maxLog = 200

    // Agent health cache — avoids a network round-trip on every request.
    private var cachedAgentOnline: Bool = false
    private var lastHealthCheck:   Date = .distantPast

    // MARK: - Public entry point

    /// Classify the prompt, run pre-flight checks, and execute. No view logic.
    func handle(
        prompt:  String,
        context: RouterContext,
        apiKey:  String,
        capture: ScreenCaptureService
    ) async -> RouteResult {
        let decision = route(prompt: prompt, context: context)
        appendLog(RouteLogEntry(input: prompt, route: decision.route, confidence: decision.confidence))

        switch decision.route {

        case .clarificationRequired:
            if let spec = decision.clarificationSpec {
                return .clarifyWith(spec: spec)
            }
            return .clarify(decision.clarificationQuestion
                            ?? "Can you be more specific about what you'd like me to do?")

        case .confirmationRequired:
            let action = PendingAction(
                toolName: "guarded_action",
                description: decision.confirmationSummary ?? prompt,
                params: ["prompt": AnyCodable(prompt)]
            )
            return .confirm(action)

        case .permissionRequired:
            return .permission(decision.permissionNeeded
                               ?? "A required permission is missing. Check System Settings → Privacy & Security.")

        case .localResponse:
            return .reply(localReply(for: prompt), route: .localResponse)

        case .spotifyControl:
            let args   = spotifyArgs(from: prompt)
            let result = await MiraToolService.execute(name: "control_spotify", argsJSON: args)
            return .reply(result, route: .spotifyControl)

        case .openURL:
            if let url = extractURL(from: prompt) {
                guard validateURL(url) else {
                    let action = PendingAction(
                        toolName: "guarded_action",
                        description: "Open \(url.absoluteString)",
                        params: ["prompt": AnyCodable(prompt)]
                    )
                    return .confirm(action)
                }
                NSWorkspace.shared.open(url)
                return .reply("Opened \(url.host ?? url.absoluteString) in your browser.", route: .openURL)
            }
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .openURL)

        case .memoryQuery:
            let q      = extractMemoryQuery(from: prompt)
            let safeQ  = q.replacingOccurrences(of: "\"", with: "\\\"")
            let result = await MiraToolService.execute(
                name: "recall_memories",
                argsJSON: "{\"query\":\"\(safeQ)\"}"
            )
            return .reply(result, route: .memoryQuery)

        case .screenGuidance:
            return await screenGuidanceResult(prompt: prompt, apiKey: apiKey, capture: capture)

        case .memoryWrite, .fileOperation, .calendarAction, .notesAction,
             .agentTask, .websiteBuilder, .composioAction, .higherModel:
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: decision.route)
        }
    }

    // MARK: - Classification (pure, synchronous, no side effects)

    func route(prompt: String, context: RouterContext) -> RouteDecision {
        let lower   = prompt.lowercased()
        let trimmed = prompt.trimmingCharacters(in: .whitespaces)

        // Safety first
        if let (summary, _) = detectDangerousCommand(lower) {
            return RouteDecision(route: .confirmationRequired, confidence: 0.95,
                                 explanation: "Potentially destructive command",
                                 confirmationSummary: "This could be destructive: \(summary)\n\nContinue?",
                                 isDangerous: true)
        }

        // Explicit memory operations
        if matchesMemoryWrite(lower) {
            return RouteDecision(route: .memoryWrite, confidence: 0.88,
                                 explanation: "Storing a preference or fact")
        }
        if matchesMemoryQuery(lower) {
            return RouteDecision(route: .memoryQuery, confidence: 0.88,
                                 explanation: "Querying stored memory")
        }

        // Media
        if matchesSpotify(lower) {
            return RouteDecision(route: .spotifyControl, confidence: 0.92,
                                 explanation: "Spotify control")
        }

        // URL open
        if let url = extractURL(from: trimmed) {
            if !validateURL(url) {
                return RouteDecision(route: .confirmationRequired, confidence: 0.80,
                                     explanation: "Suspicious URL detected",
                                     confirmationSummary: "Open \(url.absoluteString)?")
            }
            return RouteDecision(route: .openURL, confidence: 0.92,
                                 explanation: "Open URL in browser")
        }

        // App integrations
        if matchesCalendar(lower) {
            return RouteDecision(route: .calendarAction, confidence: 0.85,
                                 explanation: "Calendar action")
        }
        if matchesNotes(lower) {
            return RouteDecision(route: .notesAction, confidence: 0.85,
                                 explanation: "Notes action")
        }
        if matchesFileOperation(lower) {
            return RouteDecision(route: .fileOperation, confidence: 0.80,
                                 explanation: "File system operation")
        }

        // Screen awareness (permission check happens in handle())
        if matchesScreenGuidance(lower) {
            return RouteDecision(route: .screenGuidance, confidence: 0.88,
                                 explanation: "Screen-aware question")
        }

        // Website builder
        if matchesWebsiteBuilder(lower) {
            if isWebsiteBuilderAmbiguous(prompt) {
                return RouteDecision(route: .clarificationRequired, confidence: 0.80,
                                     explanation: "Need more website details",
                                     clarificationSpec: .websiteBuilder())
            }
            return RouteDecision(route: .websiteBuilder, confidence: 0.85,
                                 explanation: "Website builder agent")
        }

        // Multi-step agent task
        if matchesAgentTask(lower) {
            return RouteDecision(route: .agentTask, confidence: 0.75,
                                 explanation: "Multi-step background task")
        }

        // Local conversational
        if matchesLocalResponse(lower) {
            return RouteDecision(route: .localResponse, confidence: 0.92,
                                 explanation: "Simple conversational reply")
        }

        // High ambiguity
        if isHighlyAmbiguous(trimmed, context: context) {
            return RouteDecision(route: .clarificationRequired, confidence: 0.65,
                                 explanation: "Request too vague",
                                 clarificationQuestion: "I want to help — can you tell me more about what you'd like me to do?")
        }

        // Default
        return RouteDecision(route: .higherModel, confidence: 0.60,
                             explanation: "General reasoning via Claude")
    }

    // MARK: - Detection helpers (pure)

    private func detectDangerousCommand(_ lower: String) -> (summary: String, level: String)? {
        let patterns: [(trigger: String, summary: String)] = [
            // Shell-level destruction
            ("rm -rf /",        "Delete entire filesystem"),
            ("rm -rf ~",        "Delete home directory"),
            ("sudo rm -rf",     "Delete files as superuser"),
            ("chmod -r 777 /",  "Change root permissions"),
            ("mkfs",            "Format a disk"),
            ("dd if=",          "Raw disk overwrite"),
            (":(){ :|:& };:",   "Fork bomb"),
            // Mass file destruction
            ("delete everything",   "Delete everything in the target location"),
            ("delete all files",    "Delete all files"),
            ("delete all ",         "Delete all items in a location"),
            ("delete my ",          "Delete a user-owned item"),
            ("wipe everything",     "Wipe all data"),
            ("wipe all",            "Wipe all data"),
            ("erase everything",    "Erase all data"),
            ("erase all",           "Erase all data"),
            ("overwrite all",       "Overwrite all files"),
            ("format my disk",      "Format disk"),
            ("format my drive",     "Format drive"),
            ("erase my disk",       "Erase disk"),
            // Mass communication
            ("send email to all",   "Send email to all users"),
            ("send to all users",   "Send to all users"),
            ("email everyone",      "Email everyone"),
            ("message everyone",    "Message everyone"),
            ("blast everyone",      "Message blast to everyone"),
            // Data exposure
            ("upload my contacts",  "Upload contacts to external server"),
            ("share my contacts",   "Share personal contacts"),
            ("export my contacts",  "Export contacts list"),
        ]
        for p in patterns where lower.contains(p.trigger) {
            return (p.summary, "high")
        }
        return nil
    }

    private func matchesMemoryWrite(_ lower: String) -> Bool {
        if lower.hasPrefix("remember ") { return true }
        return ["from now on", "i prefer ", "my preference is", "i always like",
                "note that i", "keep in mind that", "my name is", "call me ",
                "i want you to know", "store this"].contains { lower.contains($0) }
    }

    private func matchesMemoryQuery(_ lower: String) -> Bool {
        ["do you remember", "what do you know about me", "what did i tell you",
         "did i mention", "recall what"].contains { lower.contains($0) }
    }

    private func matchesSpotify(_ lower: String) -> Bool {
        lower.contains("spotify")
    }

    func extractURL(from text: String) -> URL? {
        // Explicit scheme
        let words = text.split(separator: " ").map(String.init)
        if let explicit = words.compactMap({ URL(string: $0) })
            .first(where: { ["https","http"].contains($0.scheme ?? "") }) {
            return explicit
        }
        // "open/go to/visit <domain>"
        let openPrefixes = ["open ", "go to ", "visit ", "navigate to ", "take me to "]
        for prefix in openPrefixes {
            if let range = text.lowercased().range(of: prefix) {
                let remainder = String(text[range.upperBound...])
                    .split(separator: " ").first.map(String.init) ?? ""
                if remainder.contains(".") {
                    let urlStr = remainder.hasPrefix("http") ? remainder : "https://\(remainder)"
                    if let url = URL(string: urlStr), url.host != nil { return url }
                }
            }
        }
        return nil
    }

    private func validateURL(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        let shorteners = ["bit.ly","tinyurl.com","t.co","goo.gl","ow.ly","buff.ly"]
        if shorteners.contains(where: { host.hasSuffix($0) }) { return false }
        // Raw IP addresses get confirmation
        let ipPattern = #"^\d{1,3}(\.\d{1,3}){3}$"#
        if host.range(of: ipPattern, options: .regularExpression) != nil { return false }
        return true
    }

    private func matchesCalendar(_ lower: String) -> Bool {
        ["calendar", "add event", "create event", "what's on my schedule", "upcoming events",
         "set a reminder", "schedule a meeting", "book a time"].contains { lower.contains($0) }
    }

    private func matchesNotes(_ lower: String) -> Bool {
        ["save to notes", "create a note", "add to notes", "write this down",
         "take a note", "make a note", "note this"].contains { lower.contains($0) }
    }

    private func matchesFileOperation(_ lower: String) -> Bool {
        ["create a file", "make a file", "read the file", "list files", "list directory",
         "find the file", "move the file", "copy the file", "delete the file",
         "show me files", "what files are"].contains { lower.contains($0) }
    }

    private func matchesScreenGuidance(_ lower: String) -> Bool {
        ["what am i looking at", "what's on my screen", "what is on my screen",
         "read my screen", "look at my screen", "analyze my screen", "analyze this screen",
         "what do you see", "explain this", "translate this", "summarize this",
         "where do i click", "show me where", "what's open on",
         "describe what's on", "what's on screen"].contains { lower.contains($0) }
    }

    private func matchesWebsiteBuilder(_ lower: String) -> Bool {
        let buildVerbs = ["build", "create", "make", "design", "develop"]
        let webNouns   = ["website", "landing page", "web page"]
        return buildVerbs.contains { lower.contains($0) }
            && webNouns.contains   { lower.contains($0) }
    }

    private func isWebsiteBuilderAmbiguous(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        // Needs a specific industry/type AND a name indicator to route directly
        let specificTypes = ["saas", "agency", "ecommerce", "e-commerce", "portfolio",
                             "restaurant", "shop", "store", "blog", "fintech", "healthcare",
                             "nonprofit", "consulting", "roofing", "legal", "medical",
                             "fitness", "real estate", "startup", "corporate"]
        let hasType = specificTypes.contains { lower.contains($0) }
        // "called X" or "named X" or "for [non-generic proper noun]"
        let hasName = lower.contains("called ") || lower.contains("named ")
                   || (lower.contains(" for ") && !lower.contains("for my ")
                                               && !lower.contains("for a ")
                                               && !lower.contains("for our "))
        return !(hasType && hasName)
    }

    private func matchesAgentTask(_ lower: String) -> Bool {
        ["research ", "write a report", "write a full ", "write a complete ",
         "create a plan", "build a plan", "build me a complete", "create a complete",
         "help me plan", "help me build", "help me create", "help me write",
         "help me automate", "automate my ", "set up automation",
         "generate a ", "draft a ", "work on ", "analyze ", "look into ",
         "investigate ", "find information about", "compile a list",
         "create a funnel", "build a funnel", "set up a funnel",
         "give me a summary", "summarize the ", "make me a plan",
         "build a strategy", "create a strategy"].contains { lower.contains($0) }
    }

    private func matchesLocalResponse(_ lower: String) -> Bool {
        guard lower.split(separator: " ").count <= 6 else { return false }
        let normalized = lower.trimmingCharacters(in: .punctuationCharacters)
        let exact = Set(["hi","hello","hey","thanks","thank you","ok","okay",
                         "got it","sounds good","cool","perfect","great","awesome",
                         "bye","goodbye","nice","yep","nope","yes","no"])
        if exact.contains(normalized) { return true }
        return ["who are you","what are you","what can you do","hi mira","hello mira","hey mira"]
            .contains { normalized.hasPrefix($0) }
    }

    private func isHighlyAmbiguous(_ text: String, context: RouterContext) -> Bool {
        let lower      = text.lowercased()
        let normalized = lower.trimmingCharacters(in: .punctuationCharacters)

        // Single-word / two-word vague commands
        let vagueExact = Set([
            "do it", "that", "it", "this", "fix it", "fix that", "the thing", "go",
            "fix this", "do it for me", "make it better", "make it work", "make this better",
            "just do it", "handle it", "take care of it",
            "help", "help me",
        ])
        if vagueExact.contains(normalized) { return true }

        // Prefix-based vague patterns
        let vagueStarts = [
            "idk", "idk just", "not sure just",
            "make me something", "make something", "make me a thing",
            "build something", "create something", "design something",
            "create an app", "build an app", "make an app",
            "design a logo", "create a logo", "make a logo",
            "make it", "fix it", "do something",
        ]
        if vagueStarts.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") }) {
            return true
        }

        // "just help me with..." patterns
        if lower.contains("just help me with") || lower.contains("idk just") { return true }

        // Very short with no conversation history
        return text.split(separator: " ").count <= 2 && context.recentMessageCount == 0
    }

    // MARK: - Execution helpers

    private func localReply(for prompt: String) -> String {
        let lower = prompt.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if lower.hasPrefix("hi") || lower.hasPrefix("hello") || lower.hasPrefix("hey") {
            return "Hi! I'm Mira — your always-on Mac companion. What can I help you with?"
        }
        if lower.contains("who are you") || lower.contains("what are you") {
            return "I'm Mira — I can control Spotify, read your screen, save notes, run files and shell commands, manage calendar events, research topics, and handle long tasks in the background."
        }
        if lower.contains("what can you do") {
            return "Voice and text commands for Spotify, apps, screen reading, notes, files, calendar, web research, and background agent tasks. Just ask."
        }
        if lower.contains("thanks") || lower.contains("thank you") { return "Happy to help!" }
        if lower.contains("bye") || lower.contains("goodbye")      { return "I'll be here when you need me." }
        return "Got it."
    }

    private func spotifyArgs(from prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("pause")                                   { return "{\"action\":\"pause\"}" }
        if lower.contains("next") || lower.contains("skip")         { return "{\"action\":\"next\"}" }
        if lower.contains("previous") || lower.contains("back")     { return "{\"action\":\"previous\"}" }
        // "play X on spotify" or "play X"
        if let start = lower.range(of: "play ") {
            var song = String(lower[start.upperBound...])
            if let end = song.range(of: " on spotify") { song = String(song[..<end.lowerBound]) }
            song = song.trimmingCharacters(in: .whitespaces)
                       .replacingOccurrences(of: "\"", with: "\\\"")
            if !song.isEmpty { return "{\"action\":\"play_song\",\"song\":\"\(song)\"}" }
        }
        return "{\"action\":\"toggle\"}"
    }

    private func extractMemoryQuery(from prompt: String) -> String {
        let lower = prompt.lowercased()
        for prefix in ["do you remember ", "what do you know about ", "recall ", "what did i tell you about "] {
            if let r = lower.range(of: prefix) {
                return String(prompt[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return prompt
    }

    private func screenGuidanceResult(
        prompt:  String,
        apiKey:  String,
        capture: ScreenCaptureService
    ) async -> RouteResult {
        guard CGPreflightScreenCaptureAccess() else {
            return .permission("Screen Recording lets Mira see your screen to show you where to click.",
                               for: .screenRecording)
        }
        let screenshot = try? await capture.captureMainDisplay()
        let claude     = ClaudeService(apiKey: apiKey)
        let text       = (try? await claude.ask(prompt: prompt, screenshot: screenshot))
                         ?? "I couldn't process your screen request."
        var target: GuidanceTarget? = nil
        if let img = screenshot {
            target = try? await claude.locateGuidanceTarget(goal: prompt, in: img)
        }
        return RouteResult(route: .screenGuidance, reply: text,
                           pendingConfirmation: nil, clarificationQuestion: nil,
                           permissionNeeded: nil, guidanceTarget: target)
    }

    private func agentOrFallback(
        prompt:  String,
        apiKey:  String,
        capture: ScreenCaptureService,
        route:   MiraRoute
    ) async -> RouteResult {
        let online = await checkAgentHealth()
        if online {
            do {
                let result = try await AgentService.shared.run(prompt: prompt, claudeApiKey: apiKey)
                if let pending = result.requiresConfirmation { return .confirm(pending) }
                return .reply(result.reply, route: route)
            } catch { /* fall through */ }
        }
        let screenshot = try? await capture.captureMainDisplay()
        let claude     = ClaudeService(apiKey: apiKey)
        let text       = (try? await claude.ask(prompt: prompt, screenshot: screenshot))
                         ?? "I had trouble processing that request."
        return .reply(text, route: route)
    }

    private func checkAgentHealth() async -> Bool {
        if Date().timeIntervalSince(lastHealthCheck) < 30 { return cachedAgentOnline }
        cachedAgentOnline = await AgentService.shared.checkHealth()
        lastHealthCheck   = Date()
        return cachedAgentOnline
    }

    // MARK: - Logging

    private func appendLog(_ entry: RouteLogEntry) {
        recentLog.append(entry)
        if recentLog.count > maxLog { recentLog.removeFirst() }
    }
}
