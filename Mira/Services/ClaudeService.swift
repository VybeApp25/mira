import Foundation
import AppKit

class ClaudeService {
    private let apiKey: String
    private let model = "claude-haiku-4-5-20251001"
    private let guidanceModel = "claude-sonnet-4-6"
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Request / Response types

    private struct APIRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [APIMessage]
    }

    private struct APIMessage: Encodable {
        let role: String
        let content: [APIContent]
    }

    private enum APIContent: Encodable {
        case text(String)
        case image(String, String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let t):
                try c.encode("text", forKey: .type)
                try c.encode(t, forKey: .text)
            case .image(let data, let mime):
                try c.encode("image", forKey: .type)
                var src = c.nestedContainer(keyedBy: SrcKeys.self, forKey: .source)
                try src.encode("base64", forKey: .type)
                try src.encode(mime, forKey: .mediaType)
                try src.encode(data, forKey: .data)
            }
        }

        enum CodingKeys: String, CodingKey { case type, text, source }
        enum SrcKeys: String, CodingKey { case type, mediaType = "media_type", data }
    }

    private struct APIResponse: Decodable {
        let content: [Block]
        struct Block: Decodable { let type: String; let text: String? }
        var text: String { content.compactMap(\.text).joined() }
    }

    // MARK: - Public

    func ask(prompt: String, screenshot: NSImage? = nil, system: String = MiraPrompts.system, modelOverride: String? = nil, maxTokensOverride: Int? = nil) async throws -> String {
        var content: [APIContent] = []
        if let img = screenshot, let b64 = img.pngBase64() {
            content.append(.image(b64, "image/png"))
        }
        content.append(.text(prompt))

        let maxTokens = maxTokensOverride ?? (screenshot != nil ? 800 : 400)
        let body = APIRequest(model: modelOverride ?? model, max_tokens: maxTokens, system: system,
                              messages: [APIMessage(role: "user", content: content)])

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        // ~40 tokens/sec is a conservative estimate for Sonnet; minimum 120 s.
        req.timeoutInterval = max(120, Double(maxTokens) / 40)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api(msg)
        }
        return try JSONDecoder().decode(APIResponse.self, from: data).text
    }

    /// Session intelligence query — higher token budget, focused on work history.
    func queryProjectHistory(question: String, context: String) async throws -> String {
        let prompt = "Project Work History:\n\n\(context)\n\nQuestion: \(question)"
        let body   = APIRequest(
            model:      model,
            max_tokens: 1200,
            system:     MiraPrompts.sessionIntelligence,
            messages:   [APIMessage(role: "user", content: [.text(prompt)])]
        )
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey,          forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",    forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api(msg)
        }
        return try JSONDecoder().decode(APIResponse.self, from: data).text
    }

    /// Phase 13B — background proposal generation.
    /// Produces a concrete proposal artifact (investigation/refactor/test/migration).
    /// Still read-only: no filesystem writes. Proposal content goes to ProposalStore.
    func generateProposal(resumePrompt: String, sessionContext: String) async throws -> ProposalResult {
        let prompt = """
        Resume Context:
        \(resumePrompt)

        Session History:
        \(sessionContext)

        Produce ONE concrete proposal for advancing this project.
        Respond ONLY with a single JSON object — no markdown wrapper, no explanation:
        {
          "type": "investigation|refactor|test|migration",
          "title": "Short specific title (max 60 chars)",
          "rationale": "1-2 sentences: why this proposal is the right next step",
          "content": "Full proposal in markdown (100-400 words). Be specific — name files, functions, patterns.",
          "confidence": 0.75,
          "affected_files": ["relative/path/to/file.swift"],
          "should_block": false,
          "block_reason": null
        }
        Set should_block=true if the project context is insufficient to produce a useful proposal.
        Use type "investigation" if uncertain which change to make — describe what needs deeper analysis.
        """
        let body = APIRequest(
            model:      model,
            max_tokens: 1000,
            system:     MiraPrompts.proposalGeneration,
            messages:   [APIMessage(role: "user", content: [.text(prompt)])]
        )
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey,              forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api(String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        let text = try JSONDecoder().decode(APIResponse.self, from: data).text
        return parseProposalResult(from: text)
    }

    private func parseProposalResult(from text: String) -> ProposalResult {
        struct Raw: Decodable {
            let type:           String
            let title:          String
            let rationale:      String
            let content:        String
            let confidence:     Double
            let affected_files: [String]
            let should_block:   Bool
            let block_reason:   String?
        }
        if let range = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let jsonData = String(text[range]).data(using: .utf8),
           let raw = try? JSONDecoder().decode(Raw.self, from: jsonData) {
            return ProposalResult(
                type:          ProposalType(rawValue: raw.type) ?? .investigation,
                title:         raw.title,
                rationale:     raw.rationale,
                content:       raw.content,
                confidence:    raw.confidence,
                affectedFiles: raw.affected_files,
                shouldBlock:   raw.should_block,
                blockReason:   raw.block_reason
            )
        }
        return ProposalResult(
            type: .investigation, title: "Background analysis",
            rationale: "Unable to parse structured proposal.",
            content: text, confidence: 0.3, affectedFiles: [],
            shouldBlock: false, blockReason: nil
        )
    }

    /// Phase 13A — background analysis session.
    /// Read-only: returns a structured checkpoint describing what the agent found.
    /// No file writes, no external tools. Caller enforces the 10-minute timeout policy.
    func backgroundAnalysis(resumePrompt: String, sessionContext: String) async throws -> BackgroundWorkResult {
        let prompt = """
        Resume Context:
        \(resumePrompt)

        Session History:
        \(sessionContext)

        Respond ONLY with a single JSON object — no markdown, no explanation, no preamble:
        {
          "checkpoint_title": "Short specific title (max 60 chars) describing what you analyzed",
          "checkpoint_summary": "1-3 sentences: key findings, risks, or blockers you identified",
          "agent_context": "1-2 sentences: exact next step for the next session to pick up from",
          "should_block": false,
          "block_reason": null
        }
        Set should_block=true if you cannot make useful progress (insufficient context, needs user decision, or criteria are already met).
        """
        let body = APIRequest(
            model:      model,
            max_tokens: 600,
            system:     MiraPrompts.backgroundWork,
            messages:   [APIMessage(role: "user", content: [.text(prompt)])]
        )
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey,              forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api(String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        let text = try JSONDecoder().decode(APIResponse.self, from: data).text
        return parseBackgroundWorkResult(from: text)
    }

    private func parseBackgroundWorkResult(from text: String) -> BackgroundWorkResult {
        struct Raw: Decodable {
            let checkpoint_title:   String
            let checkpoint_summary: String
            let agent_context:      String
            let should_block:       Bool
            let block_reason:       String?
        }
        // Extract the first JSON object from the response
        if let range = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let jsonData = String(text[range]).data(using: .utf8),
           let raw = try? JSONDecoder().decode(Raw.self, from: jsonData) {
            return BackgroundWorkResult(
                checkpointTitle:   raw.checkpoint_title,
                checkpointSummary: raw.checkpoint_summary,
                agentContext:      raw.agent_context,
                shouldBlock:       raw.should_block,
                blockReason:       raw.block_reason
            )
        }
        // Fallback: use raw text as summary if JSON parsing fails
        return BackgroundWorkResult(
            checkpointTitle:   "Background analysis",
            checkpointSummary: String(text.prefix(200)),
            agentContext:      "Continue from previous checkpoint.",
            shouldBlock:       false,
            blockReason:       nil
        )
    }

    func locateGuidanceTarget(goal: String, in screenshot: NSImage) async throws -> GuidanceTarget? {
        let startTime = Date()
        let prompt = """
        Find the UI element that answers: "\(goal)"

        Respond ONLY with JSON (no markdown, no explanation):
        {
          "label": "Short element name (1-4 words)",
          "x": <left edge in physical pixels from left of image>,
          "y": <top edge in physical pixels from top of image>,
          "width": <element width in physical pixels>,
          "height": <element height in physical pixels>,
          "explanation": "One sentence: what this element is and why it answers the question",
          "confidence": 0.90
        }

        If the element is not visible: {"label":"","x":0,"y":0,"width":0,"height":0,"explanation":"Not visible on screen","confidence":0}
        """

        let raw = try await ask(prompt: prompt, screenshot: screenshot,
                                system: MiraPrompts.guidance, modelOverride: guidanceModel)

        struct Raw: Decodable {
            let label: String
            let x, y, width, height: Double
            let explanation: String
            let confidence: Double
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let range = raw.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
              let data = String(raw[range]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Raw.self, from: data),
              decoded.confidence > 0.0,
              decoded.width > 0, decoded.height > 0 else {
            #if DEBUG
            let latency = Date().timeIntervalSince(startTime)
            print("[Guidance] PARSE FAIL goal=\"\(goal)\" latency=\(String(format: "%.2f", latency))s raw=\(raw.prefix(200))")
            saveGuidanceDiagnostic(goal: goal, screenshot: screenshot, raw: raw, target: nil)
            #endif
            return nil
        }

        let rect = CGRect(
            x: decoded.x / scale,
            y: decoded.y / scale,
            width: decoded.width / scale,
            height: decoded.height / scale
        )

        let target = GuidanceTarget(
            id: UUID(),
            rect: rect,
            confidence: decoded.confidence,
            label: decoded.label,
            explanation: decoded.explanation
        )

        #if DEBUG
        let latency = Date().timeIntervalSince(startTime)
        print("""
        [Guidance] goal="\(goal)"
          image: \(Int(screenshot.size.width))×\(Int(screenshot.size.height)) px (scale=\(scale) → \(Int(screenshot.size.width/scale))×\(Int(screenshot.size.height/scale)) pts)
          model: label="\(decoded.label)" x=\(Int(decoded.x)) y=\(Int(decoded.y)) w=\(Int(decoded.width)) h=\(Int(decoded.height)) conf=\(decoded.confidence)
          logical rect: (\(Int(rect.origin.x)),\(Int(rect.origin.y))) \(Int(rect.width))×\(Int(rect.height)) pts
          explanation: \(decoded.explanation)
          latency: \(String(format: "%.2f", latency))s
        """)
        saveGuidanceDiagnostic(goal: goal, screenshot: screenshot, raw: raw, target: target)
        #endif

        return target
    }

    #if DEBUG
    private func saveGuidanceDiagnostic(goal: String, screenshot: NSImage, raw: String, target: GuidanceTarget?) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mira/Guidance")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        if let b64 = screenshot.pngBase64(), let data = Data(base64Encoded: b64) {
            try? data.write(to: base.appendingPathComponent("\(ts)_screenshot.png"))
        }
        try? raw.write(to: base.appendingPathComponent("\(ts)_response.json"),
                       atomically: true, encoding: .utf8)
        let summary = """
        goal: \(goal)
        label: \(target?.label ?? "nil")
        confidence: \(target?.confidence ?? 0)
        rect: \(target.map { "\($0.rect)" } ?? "nil")
        explanation: \(target?.explanation ?? "nil")
        """
        try? summary.write(to: base.appendingPathComponent("\(ts)_target.txt"),
                           atomically: true, encoding: .utf8)
    }
    #endif

    func locateElement(_ description: String, in screenshot: NSImage) async throws -> CGPoint? {
        let prompt = """
        Find "\(description)" in this screenshot.
        Respond with ONLY JSON: {"x": <pixels from left>, "y": <pixels from top>}
        If not visible, respond: {"x": -1, "y": -1}
        """
        let raw = try await ask(prompt: prompt, screenshot: screenshot, system: MiraPrompts.vision)

        guard let range = raw.range(of: #"\{[^}]+\}"#, options: .regularExpression),
              let data = String(raw[range]).data(using: .utf8),
              let coords = try? JSONDecoder().decode([String: Double].self, from: data),
              let x = coords["x"], let y = coords["y"], x >= 0, y >= 0 else {
            return nil
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return CGPoint(x: x / scale, y: y / scale)
    }
}

// MARK: - Prompts

enum MiraPrompts {
    static let system = """
    You are Mira, a screen-aware Mac assistant. Be concise and direct — lead with the answer, no preamble.
    When asked to find something on screen, locate it precisely.
    Always confirm before any externally visible action (send email, create event, post, etc).
    Keep replies under 80 words.
    """

    // Voice-optimised prompt for the Realtime API — short, spoken, no markdown.
    static let realtimeSystem = """
    You are Mira, a screen-aware Mac assistant speaking out loud. Keep responses under 40 words. \
    You are speaking, not writing — no markdown, no bullet points, no lists. Lead with the answer. \
    Be direct and conversational. Confirm before any externally visible action (send email, create event, post). \
    You may call multiple tools in sequence within a single response before speaking. \
    Use get_current_context whenever the user references something on screen, selected text, or clipboard. \
    Use recall_memories before answering personalised questions or making recommendations. \
    When recalling something, reinforce with natural phrasing — "I remember you use Safari" — and never just recite raw keys. \
    SAVE INTENT: Call save_content when the user asks to save, store, keep, or export anything — \
    destination "notes" for ideas/drafts/text, "files" for documents/exports. \
    Call remember ONLY for explicit user preferences, habits, or identity facts ("I prefer", "from now on", "remember that"). \
    Never call remember for content. If save intent is ambiguous, ask one clarifying question before calling either tool. \
    MAC CONTROL: \
    Use control_spotify to play, pause, or play a specific song on Spotify. \
    When the user says "play [song] on Spotify" or "open Spotify and play [song]", call open_application("Spotify") then control_spotify(action:"play_song", song:"..."). \
    Use run_apple_script for anything requiring deep app control — sending iMessages, typing in apps, clicking UI elements, composing emails via Mail, automating Finder. \
    Use run_shell_command for file operations, reading files, system info, or any terminal task. \
    Use set_volume to change the Mac's volume. \
    Use type_text to type into the currently focused app (requires Accessibility permission). \
    POINTING: When you tell the user where to look, click, or find something on screen, \
    append <point x=N y=N> at the very end of your response (after all spoken words), \
    where x and y are the UI element's position as fractions of screen width/height from the top-left (0.0–1.0). \
    Example: "Click the red button in the top-right corner <point x=0.91 y=0.04>". \
    Only use this tag when referencing a specific on-screen element location — never for abstract answers.
    """

    static let vision = """
    You are a precise UI element locator. Return only a JSON object with pixel coordinates.
    Analyze the screenshot carefully. Coordinates are from the top-left corner of the image.
    """

    static let guidance = """
    You are a precise UI element locator for a screen guidance overlay. \
    Analyze the screenshot and return the bounding box of the exact UI element that answers the user's question. \
    Coordinates are physical pixels measured from the top-left corner of the image. \
    The bounding box should tightly enclose the element — not the whole panel or window. \
    Return ONLY the JSON object, no markdown, no preamble, no trailing text.
    """

    /// Phase 13B proposal generation — produces a concrete artifact proposal.
    static let proposalGeneration = """
    You are Mira, generating a background proposal artifact. \
    You are an autonomous analyst — you CANNOT modify files or run commands. \
    Your output is a single JSON proposal that will be stored as a candidate artifact for human review. \
    Proposals must be specific: name real files, functions, patterns, or test cases from the provided context. \
    A generic proposal is worthless — write something a developer could act on directly. \
    Set should_block=true if the context is too thin to produce a useful proposal.
    """

    /// Phase 13A background analysis — read-only observer, no filesystem writes.
    static let backgroundWork = """
    You are Mira, running a background analysis session. \
    You are an autonomous observer — you CANNOT modify files, run commands, or call external services. \
    Your entire output is a single JSON checkpoint describing what you analyzed and what should happen next. \
    Be specific, factual, and concise. Reference actual file names, checkpoint titles, and session numbers from the context. \
    If you cannot make useful progress, set should_block to true with a clear reason. \
    Never fabricate details not present in the provided context.
    """

    static let sessionIntelligence = """
    You are Mira, answering questions about a project's work history. \
    You have access to session records: who worked (personas), what was done, \
    which files were created, checkpoint titles, and when each session occurred. \
    Answer factually from the provided data — reference session numbers, persona names, \
    and artifact filenames by name. If the answer isn't in the records, say so clearly. \
    Keep replies under 120 words. No markdown.
    """
}

// MARK: - Errors

enum MiraError: LocalizedError {
    case api(String)
    case noKey
    case limitReached

    var errorDescription: String? {
        switch self {
        case .api(let m): return "API error: \(m)"
        case .noKey: return "Add your Claude API key in Settings."
        case .limitReached: return "Daily limit reached — upgrade to Pro for unlimited use."
        }
    }
}

// MARK: - NSImage helper

extension NSImage {
    func pngBase64() -> String? {
        guard let tiff = tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
}
