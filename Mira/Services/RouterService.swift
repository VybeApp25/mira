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
    case musicQuery             = "music_query"
    case openURL                = "open_url"
    case memoryQuery            = "memory_query"
    case memoryWrite            = "memory_write"
    case fileOperation          = "file_operation"
    case calendarAction         = "calendar_action"
    case notesAction            = "notes_action"
    case composioAction         = "composio_action"
    case stockLookup            = "stock_lookup"
    case weatherLookup          = "weather_lookup"
    case webSearch              = "web_search"
    case imageSearch            = "image_search"
    case placeSearch            = "place_search"
    case mapsQuery              = "maps_query"
    case computerUse            = "computer_use"
    case findMyDevices          = "findmy_devices"
    case gptQuery               = "gpt_query"
    case obsidianAction         = "obsidian_action"
    case polymarketQuery        = "polymarket_query"
    case emailTask              = "email_task"
    case researchTask           = "research_task"
    case repoTask               = "repo_task"
    case codexTask              = "codex_task"
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
        case .musicQuery:             return "Now Playing"
        case .openURL:                return "Open URL"
        case .memoryQuery:            return "Memory"
        case .memoryWrite:            return "Remember"
        case .fileOperation:          return "Files"
        case .calendarAction:         return "Calendar"
        case .notesAction:            return "Notes"
        case .composioAction:         return "Integration"
        case .stockLookup:            return "Stock"
        case .weatherLookup:          return "Weather"
        case .webSearch:              return "Web Search"
        case .imageSearch:            return "Images"
        case .placeSearch:            return "Place"
        case .mapsQuery:              return "Maps"
        case .computerUse:            return "Computer Use"
        case .findMyDevices:          return "Find My"
        case .gptQuery:               return "GPT-4o"
        case .obsidianAction:         return "Obsidian"
        case .polymarketQuery:        return "Polymarket"
        case .emailTask:              return "Email"
        case .researchTask:           return "Research"
        case .repoTask:               return "Repo"
        case .codexTask:              return "Codex"
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

    // MARK: - Haiku gate (Phase 18)

    /// Async Haiku-powered classification. Deterministic routes (safety checks, Spotify,
    /// URL open, memory ops) bypass Haiku since they don't benefit from LLM classification.
    /// Falls back to the sync `route()` if the API key is missing or the Haiku call fails.
    func classifyIntent(prompt: String, context: RouterContext, apiKey: String) async -> RouteDecision {
        // Haiku auth needs EITHER a direct key (legacy) OR a signed-in proxy
        // session — in proxy mode the Anthropic key is intentionally empty and
        // auth is the Supabase JWT, so gating on a non-empty key would silently
        // disable the entire LLM classifier and leave only keyword matching.
        let canClassify = !apiKey.isEmpty
            || (MiraBackend.useProxy && !SupabaseService.cachedAccessToken.isEmpty)
        guard canClassify else { return route(prompt: prompt, context: context) }

        let sync = route(prompt: prompt, context: context)
        switch sync.route {
        case .confirmationRequired, .permissionRequired,
             .spotifyControl, .musicQuery, .openURL, .memoryWrite, .memoryQuery,
             .emailTask, .researchTask, .repoTask, .codexTask:
            return sync
        default: break
        }

        guard let haiku = try? await haikuClassify(prompt: prompt, apiKey: apiKey) else {
            return sync
        }
        return haiku
    }

    private struct HaikuReq: Encodable {
        let model: String; let max_tokens: Int; let system: String
        let messages: [HaikuMsg]
    }
    private struct HaikuMsg: Encodable { let role: String; let content: String }
    private struct HaikuResp: Decodable {
        let content: [HaikuBlock]
        struct HaikuBlock: Decodable { let type: String; let text: String? }
        var text: String { content.compactMap(\.text).joined() }
    }
    private struct ClassifyJSON: Decodable {
        let route: String; let confidence: Double; let explanation: String
    }

    private func haikuClassify(prompt: String, apiKey: String) async throws -> RouteDecision {
        let system = """
You are a routing classifier. Output JSON on one line:
{"route":"<route>","confidence":<0-1>,"explanation":"<8 words max>"}

Routes and when to use them:
- local_response: chitchat, greetings, simple Q&A answerable without tools or live data
- screen_guidance: explain screen content, "what is this", "what am I looking at"
- agent_task: background automation, multi-step tasks requiring external tools
- website_builder: build/create a website or landing page
- spotify_control: play/pause/skip/volume music, favorite/like the current song, add it to a playlist, follow the artist
- music_query: "what song is this", "what's playing", "who sings this", "who is this by", "what am I listening to", "name this song" — identify the currently playing track
- open_url: open a URL or link
- memory_query: recall stored preferences or facts about the user
- memory_write: store a preference, fact, or instruction
- file_operation: read/write/move/list files on disk
- calendar_action: schedule, view, or manage calendar events
- notes_action: Apple Notes create/search/append
- composio_action: GitHub, Gmail, Notion, Slack, Linear, Vercel, Netlify, Google Drive, Google Docs, Google Sheets, Airtable tasks
- stock_lookup: current stock price, share price, market quote, ticker symbol lookup
- weather_lookup: weather, temperature, forecast, how hot/cold, will it rain, do I need a jacket/umbrella
- web_search: live scores, latest news, current events, "what's happening with", today's results, look it up online, search the web for something with a time-sensitive or factual answer
- image_search: show images of, pictures of, find photos of
- place_search: where is, directions to, find nearby, navigate to a location
- findmy_devices: Find My, list Apple devices, where is my iPhone/Mac/Watch/AirPods
- gpt_query: ask GPT, ask ChatGPT, use GPT-4, what does ChatGPT say
- obsidian_action: Obsidian vault, open vault note, search vault, wikilinks, markdown notes in Obsidian
- polymarket_query: Polymarket, prediction market odds, what are the chances, market probability, will X happen
- maps_query: nearby, directions to, how far, distance between, find a coffee shop, geocode, navigate to, find nearest
- computer_use: click on, type into, open the app, automate, fill out the form, control my Mac, screenshot desktop
- email_task: draft email, write email, send email, check inbox, unread emails, triage email, reply to email, email assistant
- research_task: research report, market research, competitor analysis, web research, write a report on
- repo_task: pull request, create PR, git commit, git push, code review, review this code, github issues
- codex_task: use Codex, run Codex, codex CLI, openai codex, codex exec
- higher_model: analysis, coding, writing, research, complex reasoning

Output ONLY the JSON line. No preamble, no markdown fences.
"""
        let body = HaikuReq(
            model: "claude-haiku-4-5-20251001", max_tokens: 80, system: system,
            messages: [HaikuMsg(role: "user", content: prompt)]
        )
        var req = URLRequest(url: MiraBackend.anthropicMessagesURL)
        req.httpMethod = "POST"
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 5

        let (data, resp) = try await MiraBackend.proxyData(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api("haiku-gate-\((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let raw = try JSONDecoder().decode(HaikuResp.self, from: data).text
        let clean = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = clean.data(using: .utf8),
              let parsed   = try? JSONDecoder().decode(ClassifyJSON.self, from: jsonData),
              let route    = MiraRoute(rawValue: parsed.route) else {
            throw MiraError.api("haiku-gate-parse")
        }
        return RouteDecision(route: route, confidence: parsed.confidence,
                             explanation: parsed.explanation)
    }

    // MARK: - Execution

    /// Classify the prompt, run pre-flight checks, and execute. No view logic.
    /// Pass `precomputed` to reuse a decision already made by `classifyIntent()`.
    func handle(
        prompt:        String,
        context:       RouterContext,
        apiKey:        String,
        capture:       ScreenCaptureService,
        precomputed:   RouteDecision? = nil,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> RouteResult {
        let decision = precomputed ?? route(prompt: prompt, context: context)
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

        case .musicQuery:
            // Text fallback (used when nothing is playing, or when the chat view
            // couldn't build the now-playing card). When a track IS playing, the
            // chat view renders a card with tappable action chips instead.
            let result = await MusicControlService.shared.identify()
            return .reply(result, route: .musicQuery)

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
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .openURL, onStreamChunk: onStreamChunk)

        case .memoryQuery:
            let q      = extractMemoryQuery(from: prompt)
            let safeQ  = q.replacingOccurrences(of: "\"", with: "\\\"")
            let result = await MiraToolService.execute(
                name: "recall_memories",
                argsJSON: "{\"query\":\"\(safeQ)\"}"
            )
            return .reply(result, route: .memoryQuery)

        case .screenGuidance:
            return await screenGuidanceResult(prompt: prompt, apiKey: apiKey, capture: capture, onStreamChunk: onStreamChunk)

        case .stockLookup, .imageSearch, .placeSearch:
            // Widget data is fetched in IslandChatView; this path is the text fallback.
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: decision.route, onStreamChunk: onStreamChunk)

        case .weatherLookup:
            return await weatherResult(prompt: prompt)

        case .webSearch:
            return await webSearchResult(prompt: prompt, apiKey: apiKey)

        case .mapsQuery:
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .mapsQuery, onStreamChunk: onStreamChunk)

        case .computerUse:
            // Full machine control is powerful, so it's a deliberate opt-in: only
            // when the user has turned on autonomous mode (the same switch teaching
            // mode uses, default off) does a chat request actually drive the screen.
            // Otherwise fall back to describing/guiding — a chat message can never
            // seize the computer unless the user has opted in.
            if UserDefaults.standard.bool(forKey: "mira_autonomous_enabled") {
                return await computerUseResult(prompt: prompt, apiKey: apiKey)
            }
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .computerUse, onStreamChunk: onStreamChunk)

        case .calendarAction:
            // Native Apple/iCloud Calendar via EventKit — writes the event directly in
            // the background (instant, no UI takeover), so the user keeps working. The
            // cloud (Composio) path can't reach the native calendar, and the UI agent
            // is slow and seizes the screen — both wrong for an app with a real API.
            return await calendarResult(prompt: prompt, apiKey: apiKey)

        case .findMyDevices:
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .findMyDevices, onStreamChunk: onStreamChunk)

        case .gptQuery:
            let key = OpenAIService.effectiveKey
            guard !key.isEmpty else {
                return .reply("OpenAI key not set. Add it in Mira Settings → API Keys.", route: .gptQuery)
            }
            let service = OpenAIService(apiKey: key)
            let reply   = await service.chatOrEmpty(prompt: prompt, maxTokens: 800)
            return .reply(reply.isEmpty ? "GPT-4o returned no response." : reply, route: .gptQuery)

        case .emailTask, .researchTask, .repoTask:
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: decision.route, onStreamChunk: onStreamChunk)

        case .codexTask:
            return await codexOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, onStreamChunk: onStreamChunk)

        case .obsidianAction, .polymarketQuery,
             .memoryWrite, .fileOperation, .notesAction,
             .agentTask, .websiteBuilder, .composioAction, .higherModel:
            return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: decision.route, onStreamChunk: onStreamChunk)
        }
    }

    // MARK: - Synchronous classification (pure, no side effects)

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
        // "What song is this?" must beat the Spotify play matcher — it's a question
        // about the current track, not a command to play something.
        if matchesMusicQuery(lower) {
            return RouteDecision(route: .musicQuery, confidence: 0.93,
                                 explanation: "Identify the current track")
        }
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

        // Widget routes (structured data cards)
        if matchesStockLookup(lower) {
            return RouteDecision(route: .stockLookup, confidence: 0.90,
                                 explanation: "Stock quote lookup")
        }
        if matchesWeather(lower) {
            return RouteDecision(route: .weatherLookup, confidence: 0.88,
                                 explanation: "Weather lookup")
        }
        if matchesWebSearch(lower) {
            return RouteDecision(route: .webSearch, confidence: 0.85,
                                 explanation: "Live web search")
        }
        if matchesImageSearch(lower) {
            return RouteDecision(route: .imageSearch, confidence: 0.90,
                                 explanation: "Image search")
        }
        if matchesPlaceSearch(lower) {
            return RouteDecision(route: .placeSearch, confidence: 0.87,
                                 explanation: "Place / directions lookup")
        }

        // GPT / OpenAI explicit request
        if matchesGPT(lower) {
            return RouteDecision(route: .gptQuery, confidence: 0.93,
                                 explanation: "GPT/ChatGPT explicit request")
        }

        // FindMy device list
        if matchesFindMy(lower) {
            return RouteDecision(route: .findMyDevices, confidence: 0.90,
                                 explanation: "Find My device query")
        }

        // Obsidian vault
        if matchesObsidian(lower) {
            return RouteDecision(route: .obsidianAction, confidence: 0.88,
                                 explanation: "Obsidian vault operation")
        }

        // Polymarket prediction markets
        if matchesPolymarket(lower) {
            return RouteDecision(route: .polymarketQuery, confidence: 0.90,
                                 explanation: "Prediction market query")
        }

        // Email drafting / triage
        if matchesEmailTask(lower) {
            return RouteDecision(route: .emailTask, confidence: 0.88,
                                 explanation: "Email drafting or triage task")
        }

        // Research report
        if matchesResearchTask(lower) {
            return RouteDecision(route: .researchTask, confidence: 0.86,
                                 explanation: "Research and report generation")
        }

        // Git / GitHub / repo operations
        if matchesRepoTask(lower) {
            return RouteDecision(route: .repoTask, confidence: 0.88,
                                 explanation: "Git / GitHub repository operation")
        }

        // Explicit Codex CLI request
        if matchesCodexTask(lower) {
            return RouteDecision(route: .codexTask, confidence: 0.93,
                                 explanation: "Explicit Codex CLI agent request")
        }

        // Maps / geocoding / nearby / directions (uses Python maps skill)
        if matchesMaps(lower) {
            return RouteDecision(route: .mapsQuery, confidence: 0.88,
                                 explanation: "Maps / location / directions query")
        }

        // Computer Use (explicit GUI automation request)
        if matchesComputerUse(lower) {
            return RouteDecision(route: .computerUse, confidence: 0.88,
                                 explanation: "Desktop GUI automation request")
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

    /// "What song is this / who's this by / what's playing" — an identify request,
    /// distinct from a play command. Kept tight so it doesn't swallow "play this song".
    private func matchesMusicQuery(_ lower: String) -> Bool {
        let phrases = [
            "what song is this", "what song is playing", "what's this song", "whats this song",
            "what is this song", "what track is this", "name this song", "name that song",
            "what am i listening to", "what's playing", "whats playing", "what is playing",
            "who is this by", "who's this by", "whos this by", "who sings this",
            "who is this song by", "who's this song by", "who is singing this",
            "what song", "song is this",
        ]
        return phrases.contains { lower.contains($0) }
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

    private func matchesStockLookup(_ lower: String) -> Bool {
        if lower.range(of: #"\$[a-z]{1,5}\b"#, options: .regularExpression) != nil { return true }
        return ["stock price", "stock quote", "share price", "trading at", "what is the price of",
                "how much is", "price of", "stock of", "how is"].contains { lower.contains($0) }
            && ["stock", "shares", "trading", "$"].contains { lower.contains($0) }
            || ["stock price", "stock quote", "share price", "ticker"].contains { lower.contains($0) }
    }

    private func matchesImageSearch(_ lower: String) -> Bool {
        ["show me images of", "images of ", "pictures of ", "show pictures of",
         "find images of", "search images", "image search"].contains { lower.contains($0) }
    }

    private func matchesWeather(_ lower: String) -> Bool {
        ["weather", "temperature", "forecast", "how hot", "how cold", "how warm",
         "will it rain", "is it raining", "going to rain", "do i need an umbrella",
         "do i need a jacket", "is it snowing", "how's it outside",
         "hows it outside"].contains { lower.contains($0) }
    }

    private func matchesWebSearch(_ lower: String) -> Bool {
        ["search the web", "search online", "search for", "look it up", "look up online",
         "google ", "live score", "the score", "latest news", "sports news", "current news",
         "current score", "who won", "world cup", "headlines", "what's happening with",
         "whats happening with", "what's the latest", "whats the latest", "today's results",
         "todays results"].contains { lower.contains($0) }
            || lower.range(of: #"\bscores?\b"#, options: .regularExpression) != nil
            || lower.range(of: #"\bnews\b"#,    options: .regularExpression) != nil
    }

    private func matchesGPT(_ lower: String) -> Bool {
        ["ask gpt", "ask chatgpt", "use gpt", "use chatgpt", "ask openai",
         "gpt-4", "gpt4", "chatgpt", "via gpt", "with gpt",
         "what does gpt say", "what does chatgpt say"].contains { lower.contains($0) }
    }

    private func matchesMaps(_ lower: String) -> Bool {
        let nearbyTerms = ["nearby", "near me", "closest", "find a ", "find the nearest",
                           "coffee shop", "restaurant near", "directions to", "how far is",
                           "distance from", "distance between", "route to", "route from",
                           "navigate to", "what's around", "geocode", "what is the address of"]
        let placeTerms  = ["find nearby", "find a nearby"]
        return nearbyTerms.contains { lower.contains($0) } || placeTerms.contains { lower.contains($0) }
    }

    private func matchesComputerUse(_ lower: String) -> Bool {
        ["click on", "type into", "type in the", "open the app", "drive the app",
         "automate this", "fill out the form", "use my mouse", "use computer use",
         "control my mac", "control my computer", "operate the", "screenshot my desktop",
         "click the button", "click submit", "scroll down in",
         // Explicit "drive my Mac for me" autonomy phrasing — signals desktop
         // control, not a specific app integration, so it's safe to route here
         // ahead of calendar/notes.
         "do it for me", "do this for me", "do that for me", "take over", "you do it"]
            .contains { lower.contains($0) }
    }

    private func matchesObsidian(_ lower: String) -> Bool {
        ["obsidian", "my vault", "vault note", "open vault", "search vault",
         "wikilink", "[["].contains { lower.contains($0) }
    }

    private func matchesPolymarket(_ lower: String) -> Bool {
        ["polymarket", "prediction market", "prediction odds",
         "market odds", "what are the odds", "what are the chances",
         "will it happen", "market probability"].contains { lower.contains($0) }
    }

    private func matchesFindMy(_ lower: String) -> Bool {
        ["find my", "findmy", "where is my iphone", "where is my mac", "where is my airpods",
         "where is my watch", "where is my ipad", "where are my devices",
         "track my phone", "track my device", "locate my device",
         "find my device", "find my phone", "list my devices",
         "my apple devices"].contains { lower.contains($0) }
    }

    private func matchesPlaceSearch(_ lower: String) -> Bool {
        ["where is ", "directions to ", "how do i get to ", "navigate to ",
         "find a nearby", "find nearby", "nearest "].contains { lower.contains($0) }
    }

    private func matchesScreenGuidance(_ lower: String) -> Bool {
        ["what am i looking at", "what's on my screen", "what is on my screen",
         "read my screen", "look at my screen", "analyze my screen", "analyze this screen",
         "what do you see", "explain this", "translate this", "summarize this",
         "where do i click", "show me where", "what's open on",
         "describe what's on", "what's on screen",
         // "can you see my screen?", "see my screen", "do you see", etc.
         "can you see", "see my screen", "do you see", "can you view",
         "view my screen", "you see my", "see the screen", "see what's",
         "see what i", "show my screen", "what's happening on",
         "look at what", "see this", "what is this"].contains { lower.contains($0) }
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

    private func matchesEmailTask(_ lower: String) -> Bool {
        ["draft email", "write email", "send email", "reply to email", "compose email",
         "email to ", "email draft", "check my inbox", "check inbox", "check email",
         "unread emails", "my emails", "triage email", "triage my inbox",
         "sort my emails", "reply to this email", "respond to email",
         "write a reply", "email assistant"].contains { lower.contains($0) }
    }

    private func matchesResearchTask(_ lower: String) -> Bool {
        ["research report", "market research", "competitor analysis",
         "find information about", "write a report on", "market brief",
         "compile research", "web research", "source-backed",
         "do research on", "research about", "research the"].contains { lower.contains($0) }
    }

    private func matchesRepoTask(_ lower: String) -> Bool {
        ["pull request", "create pr", "open pr", "merge pr", "review pr",
         "git commit", "git push", "git status", "git diff", "git log",
         "code review", "review this code", "review this pr",
         "create a branch", "checkout branch", "close issue", "open issue",
         "github issues", "push to github", "push to main",
         "commit this", "create a commit"].contains { lower.contains($0) }
    }

    private func matchesCodexTask(_ lower: String) -> Bool {
        ["use codex", "run codex", "codex cli", "openai codex",
         "codex exec", "codex agent"].contains { lower.contains($0) }
        || (lower.contains("codex") && ["fix ", "build ", "refactor", "write "].contains { lower.contains($0) })
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
        // Current-track actions on the playing song — check these BEFORE generic
        // play/pause so "favorite this song" doesn't fall through to a toggle.
        if lower.contains("favorite") || lower.contains("favourite")
            || lower.contains("like this") || lower.contains("like the")
            || lower.contains("save this") || lower.contains("save the") || lower.contains("heart this") {
            return "{\"action\":\"favorite\"}"
        }
        if lower.contains("add") && (lower.contains("playlist")) {
            // Try to pull a playlist name after "to " (e.g. "add this to my Gym playlist").
            if let r = lower.range(of: "to ") {
                var name = String(prompt[r.upperBound...])
                    .replacingOccurrences(of: "playlist", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "my ", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "the ", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.!?"))
                name = name.replacingOccurrences(of: "\"", with: "")
                if !name.isEmpty { return "{\"action\":\"add_to_playlist\",\"playlist\":\"\(name)\"}" }
            }
            return "{\"action\":\"add_to_playlist\"}"
        }
        if lower.contains("follow") && (lower.contains("artist") || lower.contains("them")) {
            return "{\"action\":\"follow_artist\"}"
        }
        if lower.contains("turn it up") || lower.contains("turn up") || lower.contains("louder")
            || lower.contains("volume up") { return "{\"action\":\"volume_up\"}" }
        if lower.contains("turn it down") || lower.contains("turn down") || lower.contains("quieter")
            || lower.contains("volume down") { return "{\"action\":\"volume_down\"}" }
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
        prompt:        String,
        apiKey:        String,
        capture:       ScreenCaptureService,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> RouteResult {
        guard let screenshot = try? await capture.captureMainDisplay() else {
            return .reply(
                "I can't see your screen right now. To fix this: open System Settings → Privacy & Security → Screen Recording, remove Mira if it's listed, re-add it, then relaunch Mira.",
                route: .screenGuidance
            )
        }

        let claude       = ClaudeService(apiKey: apiKey)
        let screenSystem = "You are Mira, a screen-aware Mac assistant. You CAN see the user's screen — a screenshot is attached to this message. Describe what you see accurately. Be concise and direct."

        let text: String
        if let stream = onStreamChunk {
            text = (try? await claude.askStreaming(
                prompt: prompt,
                screenshot: screenshot,
                system: screenSystem,
                maxTokensOverride: 600,
                onChunk: stream
            )) ?? "I couldn't process the screenshot. Please try again."
        } else {
            text = (try? await claude.ask(
                prompt: prompt,
                screenshot: screenshot,
                system: screenSystem,
                maxTokensOverride: 600
            )) ?? "I couldn't process the screenshot. Please try again."
        }

        let target = try? await claude.locateGuidanceTarget(goal: prompt, in: screenshot)
        return RouteResult(route: .screenGuidance, reply: text,
                           pendingConfirmation: nil, clarificationQuestion: nil,
                           permissionNeeded: nil, guidanceTarget: target)
    }

    /// Full desktop autonomy from chat/voice. Hands the task to the SAME
    /// ComputerUseService agent loop that powers the Computer Use tab (screenshot →
    /// click / double-click / type / key / scroll / drag → repeat until done), so
    /// "do it for me" actually acts outside the Learn tab instead of only describing
    /// what to do. Destructive phrasing is already caught upstream by
    /// `detectDangerousCommand` → `confirmationRequired`, and the orchestrator has
    /// its own iteration cap + Stop kill-switch. Blocks until the task finishes,
    /// then returns the agent's closing summary as the chat reply.
    private func computerUseResult(prompt: String, apiKey: String) async -> RouteResult {
        // Engine selection is INVISIBLE to the user: by default Mira picks Codex
        // computer-use vs the Claude vision loop itself (EngineRouter) and fails
        // over transparently, so they just see the task get done. "codex"/"claude"
        // are power-user overrides; "auto" (default) lets Mira decide.
        let mode = UserDefaults.standard.string(forKey: "mira_autonomy_engine") ?? "auto"
        let plan: EngineRouter.Plan
        switch mode {
        case "codex":  plan = .forced(.codex)
        case "claude": plan = .forced(.claude)
        default:       plan = await EngineRouter.shared.planDesktopControl(prompt)
        }

        // If the user drew on screen to mark WHERE to act, attach it to the task.
        // Survives a Codex→Claude failover (both engines get the same context).
        let drawn = PendingDrawnContextService.shared.pop()

        // ONE quota consume for the whole task — a Codex→Claude failover must not
        // double-charge the user's monthly task budget.
        let decision = await QuotaService.shared.consume(path: "computer-use")
        guard decision.allowed else {
            return .reply("You're out of autonomous tasks this month — \(QuotaService.shared.tasksLeftText).",
                          route: .computerUse)
        }

        // Run primary; on a refusal/failure (not a user Stop), silently retry on
        // the other engine.
        var run = await runEngine(plan.primary, task: prompt, apiKey: apiKey, drawn: drawn)
        if !run.success, let secondary = plan.secondary {
            NSLog("[EngineRouter] \(plan.primary.rawValue) did not complete (\(plan.reason)) — failing over to \(secondary.rawValue)")
            let retry = await runEngine(secondary, task: prompt, apiKey: apiKey, drawn: drawn)
            if retry.success || run.summary.isEmpty { run = retry }
        }

        // Single announcement, once the final engine has finished.
        TaskAnnouncer.shared.announce(task: prompt, success: run.success,
                                      detail: run.summary.isEmpty ? nil : run.summary)
        return .reply(run.summary.isEmpty ? "Done." : run.summary, route: .computerUse)
    }

    /// Runs one engine WITHOUT consuming quota or announcing (the caller owns both,
    /// so a failover stays a single metered task). Returns the summary + whether it
    /// completed cleanly.
    private func runEngine(_ engine: EngineRouter.Engine, task: String, apiKey: String, drawn: DrawnContext? = nil) async -> (summary: String, success: Bool) {
        switch engine {
        case .codex:
            CodexHUD.shared.show()   // live "watch Codex work" panel; stays up to show the outcome
            let summary = await CodexComputerUseService.shared.run(task: task, drawn: drawn)
            let succeeded = CodexComputerUseService.shared.lastOutcome == .succeeded
            return (summary, succeeded)
        case .claude:
            let ok = await ComputerUseOrchestrator.shared.control(task: task, apiKey: apiKey, drawn: drawn)
            let summary = ComputerUseOrchestrator.shared.result.trimmingCharacters(in: .whitespacesAndNewlines)
            return (summary, ok)
        }
    }

    /// Native calendar handling via EventKit. Extracts the event details (dates are
    /// unreliable to parse by hand) with a tiny Haiku call, then writes straight to
    /// the Apple/iCloud calendar in the background — no UI, no screen takeover.
    // MARK: - Weather (open Weather app + cheap text answer)

    /// Opens the native Weather app (visible, no screenshots) and speaks the
    /// requested city's weather from the free wttr.in API. The app gives the
    /// visual; the API gives an accurate spoken answer for the specific city.
    private func weatherResult(prompt: String) async -> RouteResult {
        let city = extractCity(from: prompt)
        // Visible path — open the Weather app and, if a city was named, drive its
        // search so the app actually shows that city (not just current location).
        await openWeatherApp(showingCity: city)
        // Spoken path — cheap text lookup for the exact city.
        if let summary = await WeatherService.lookup(city: city) {
            return .reply(summary, route: .weatherLookup)
        }
        let where_ = city.map { " for \($0)" } ?? ""
        return .reply("I opened the Weather app\(where_) for you.", route: .weatherLookup)
    }

    /// Opens (and activates) the Weather app. When a specific city is named,
    /// drives the search field — focus it via AX, type the city as real key
    /// events so the live-search list populates, then Return to open the top
    /// match — so the app visibly shows that city. Best-effort: failures are
    /// non-fatal because the spoken answer already names the right city.
    private func openWeatherApp(showingCity city: String?) async {
        let bundleID = "com.apple.weather"

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        } else {
            _ = await MiraToolService.execute(name: "open_application",
                                              argsJSON: "{\"app_name\":\"Weather\"}")
        }

        guard let city, !city.isEmpty else { return }
        // Let the window come forward before sending keystrokes to it.
        try? await Task.sleep(nanoseconds: 900_000_000)

        // Focus + clear the search field via AX (no app activation of its own).
        do {
            _ = try AXActuationService.shared.setTextValue("", inBundleID: bundleID)
        } catch {
            NSLog("[Weather] couldn't focus search field via AX: \(error.localizedDescription)")
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        ComputerUseService.shared.type(text: city)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let the results list populate
        ComputerUseService.shared.key(combination: "return")
    }

    /// Pulls a city/location out of a weather prompt ("weather in Atlanta" →
    /// "Atlanta"). Returns nil for the Mac's current location.
    private func extractCity(from prompt: String) -> String? {
        let lower = prompt.lowercased()
        guard let r = lower.range(of: " in ") else { return nil }
        var city = String(prompt[r.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!,"))
        for suffix in [" today", " right now", " tonight", " tomorrow",
                       " this week", " this weekend", " now"] {
            if city.lowercased().hasSuffix(suffix) {
                city = String(city.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return city.isEmpty ? nil : city
    }

    // MARK: - Web search (open browser + read results for accuracy)

    /// Opens the user's chosen browser to the live results page (visible, free)
    /// AND reads the answer as text via the web_search tool, so Mira speaks a
    /// verified answer while the page is on screen — no screenshot loop.
    private func webSearchResult(prompt: String, apiKey: String) async -> RouteResult {
        let query = searchQuery(from: prompt)
        let browserName: String = BrowserService.searchURL(for: query)
            .map { BrowserService.shared.open($0) } ?? "your browser"

        if let answer = await webSearchAnswer(query: prompt, apiKey: apiKey), !answer.isEmpty {
            return .reply("\(answer)\n\n_Opened the full results in \(browserName)._",
                          route: .webSearch)
        }
        return .reply("I opened the results in \(browserName) — take a look.", route: .webSearch)
    }

    /// Strips leading filler so the browser URL gets a clean query.
    private func searchQuery(from prompt: String) -> String {
        var q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["search the web for ", "search online for ", "search for ",
                       "look up ", "look it up ", "google ", "search "] {
            if q.lowercased().hasPrefix(prefix) {
                q = String(q.dropFirst(prefix.count)); break
            }
        }
        return q.isEmpty ? prompt : q
    }

    /// Reads live web results as text via Anthropic's web_search server tool
    /// (cheap, cited, no HTML scraping). Returns a short spoken answer.
    private func webSearchAnswer(query: String, apiKey: String) async -> String? {
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 500,
            "system": "You are Mira. Use web search to answer with current, accurate "
                    + "information. Reply in 1-3 plain spoken sentences. No markdown, "
                    + "no bullet lists, no citation list.",
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]],
            "messages": [["role": "user", "content": query]]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: MiraBackend.anthropicMessagesURL)
        req.httpMethod = "POST"
        guard MiraBackend.authorizeAnthropic(&req, directKey: apiKey) else { return nil }
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = httpBody
        req.timeoutInterval = 30

        guard let (data, resp) = try? await MiraBackend.proxyData(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func calendarResult(prompt: String, apiKey: String) async -> RouteResult {
        // In proxy mode the Anthropic API key is intentionally empty — auth is the
        // Supabase JWT — so "signed in" is a present JWT, not a non-empty key.
        let signedIn = MiraBackend.useProxy ? !SupabaseService.cachedAccessToken.isEmpty : !apiKey.isEmpty
        guard signedIn else {
            return .reply("I need to be signed in to manage your calendar.", route: .calendarAction)
        }
        let ctx = Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
        let system = """
        You convert a calendar request into JSON. The user's current local date and time is: \(ctx).
        Output ONE line of JSON and nothing else:
        {"action":"create"|"read","title":"<title or empty>","start":"YYYY-MM-DDTHH:MM","end":"YYYY-MM-DDTHH:MM or empty","all_day":true|false,"days_ahead":<int>}
        Rules: resolve relative dates ("today","tomorrow","Friday","next week") against the current date above. Use 24-hour LOCAL times, no timezone offset. For checking the schedule use action=read with days_ahead. For creating, fill title and start; leave end empty unless an end/duration is given.
        """
        guard let json = try? await haikuJSON(system: system, user: prompt, apiKey: apiKey) else {
            return .reply("I couldn't read that calendar request — try rephrasing the date and time.", route: .calendarAction)
        }

        if (json["action"] as? String) == "read" {
            let days = (json["days_ahead"] as? Int) ?? 1
            let result = await MiraToolService.execute(name: "get_calendar_events", argsJSON: "{\"days_ahead\":\(days)}")
            return .reply(result, route: .calendarAction)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let argsJSON = String(data: data, encoding: .utf8) else {
            return .reply("I couldn't build that event.", route: .calendarAction)
        }
        let result = await MiraToolService.execute(name: "create_calendar_event", argsJSON: argsJSON)
        return .reply(result, route: .calendarAction)
    }

    /// One-shot Haiku call that returns a parsed JSON object (used for structured
    /// extraction like calendar fields). Reuses the Haiku request/response types.
    private func haikuJSON(system: String, user: String, apiKey: String) async throws -> [String: Any] {
        let body = HaikuReq(model: "claude-haiku-4-5-20251001", max_tokens: 200, system: system,
                            messages: [HaikuMsg(role: "user", content: user)])
        var req = URLRequest(url: MiraBackend.anthropicMessagesURL)
        req.httpMethod = "POST"
        _ = MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 12

        let (data, resp) = try await MiraBackend.proxyData(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api("haiku-\((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let raw = try JSONDecoder().decode(HaikuResp.self, from: data).text
        let clean = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = clean.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw MiraError.api("haiku-json-parse")
        }
        return obj
    }

    private func codexOrFallback(
        prompt:        String,
        apiKey:        String,
        capture:       ScreenCaptureService,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> RouteResult {
        let result = await CodexService.shared.run(prompt: prompt, workdir: nil)
        if result.success && !result.output.isEmpty {
            return .reply(result.output, route: .codexTask)
        }
        return await agentOrFallback(prompt: prompt, apiKey: apiKey, capture: capture, route: .codexTask, onStreamChunk: onStreamChunk)
    }

    private func agentOrFallback(
        prompt:        String,
        apiKey:        String,
        capture:       ScreenCaptureService,
        route:         MiraRoute,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> RouteResult {
        // For general reasoning (higherModel), use Claude directly with a screenshot
        // so Mira can actually see the screen. The TypeScript agent is text-only
        // (Composio integrations) and should only be used for integration routes.
        if route == .higherModel {
            let screenshot = try? await capture.captureMainDisplay()
            let claude     = ClaudeService(apiKey: apiKey)
            if let stream = onStreamChunk {
                let text = (try? await claude.askStreaming(
                    prompt: prompt,
                    screenshot: screenshot,
                    maxTokensOverride: 600,
                    onChunk: stream
                )) ?? "I had trouble processing that request."
                return .reply(text, route: route)
            }
            let text = (try? await claude.ask(
                prompt: prompt,
                screenshot: screenshot,
                maxTokensOverride: 600
            )) ?? "I had trouble processing that request."
            return .reply(text, route: route)
        }

        let online = await checkAgentHealth()
        if online {
            do {
                let result = try await AgentService.shared.run(prompt: prompt, accessToken: SupabaseService.cachedAccessToken)
                if let pending = result.requiresConfirmation { return .confirm(pending) }
                return .reply(result.reply, route: route)
            } catch { /* fall through */ }
        }
        let screenshot = try? await capture.captureMainDisplay()
        let claude     = ClaudeService(apiKey: apiKey)
        let agentRoutes: Set<MiraRoute> = [.agentTask, .websiteBuilder, .composioAction,
                                            .emailTask, .researchTask, .repoTask, .codexTask,
                                            .fileOperation, .calendarAction, .notesAction]
        let system = agentRoutes.contains(route) ? MiraPrompts.agentMode : MiraPrompts.system
        if let stream = onStreamChunk {
            let text = (try? await claude.askStreaming(
                prompt: prompt,
                screenshot: screenshot,
                system: system,
                onChunk: stream
            )) ?? "I had trouble processing that request."
            return .reply(text, route: route)
        }
        let text = (try? await claude.ask(prompt: prompt, screenshot: screenshot, system: system))
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
