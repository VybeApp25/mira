import Foundation
import AppKit

class ClaudeService {
    private let apiKey: String
    private let model = "claude-haiku-4-5-20251001"
    private let guidanceModel = "claude-sonnet-4-6"
    // Routes to the backend proxy when enabled, else directly to Anthropic.
    private var baseURL: URL { MiraBackend.anthropicMessagesURL }

    // Shared flag so multiple ClaudeService instances only warm once per process.
    private static var tlsWarmedUp = false
    private static let tlsLock = NSLock()

    init(apiKey: String) {
        self.apiKey = apiKey
        Self.warmUpTLSIfNeeded(url: baseURL)
    }

    // Fires a no-op HEAD request to cache the TLS session ticket, so the first real
    // API call (which may carry a large image) doesn't pay the full TLS handshake cost.
    // Ported from farzaa/clicky ClaudeAPI (MIT).
    private static func warmUpTLSIfNeeded(url: URL) {
        tlsLock.lock()
        let shouldWarm = !tlsWarmedUp
        if shouldWarm { tlsWarmedUp = true }
        tlsLock.unlock()
        guard shouldWarm else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
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

    // MARK: - OpenRouter fallback types (OpenAI-compatible)

    private struct ORRequest: Encodable {
        let model: String; let max_tokens: Int; let messages: [ORMessage]
    }
    private struct ORMessage: Encodable {
        let role: String; let content: ORContent
        enum ORContent: Encodable {
            case string(String)
            case parts([ORPart])
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .string(let s): try c.encode(s)
                case .parts(let p):  try c.encode(p)
                }
            }
        }
    }
    private struct ORPart: Encodable {
        let type: String
        let text: String?
        let image_url: ORImageURL?
        struct ORImageURL: Encodable { let url: String }
        static func text(_ s: String) -> ORPart { ORPart(type: "text",      text: s, image_url: nil) }
        static func image(_ b64: String, _ mime: String) -> ORPart {
            ORPart(type: "image_url", text: nil,
                   image_url: .init(url: "data:\(mime);base64,\(b64)"))
        }
    }
    private struct ORResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Msg
            struct Msg: Decodable { let content: String }
        }
        var text: String { choices.first?.message.content ?? "" }
    }

    // MARK: - Public

    func ask(prompt: String, screenshot: NSImage? = nil, system: String = MiraPrompts.system, modelOverride: String? = nil, maxTokensOverride: Int? = nil) async throws -> String {
        var content: [APIContent] = []
        if let img = screenshot, let b64 = img.pngBase64() {
            content.append(.image(b64, "image/png"))
        }
        content.append(.text(prompt))

        let resolvedModel = modelOverride ?? model
        let maxTokens = maxTokensOverride ?? (screenshot != nil ? 800 : 400)
        let body = APIRequest(model: resolvedModel, max_tokens: maxTokens, system: system,
                              messages: [APIMessage(role: "user", content: content)])

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        // ~40 tokens/sec is a conservative estimate for Sonnet; minimum 120 s.
        req.timeoutInterval = max(120, Double(maxTokens) / 40)

        let (data, resp) = try await MiraBackend.proxyData(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            return try JSONDecoder().decode(APIResponse.self, from: data).text
        }

        // Retry via OpenRouter on rate-limit or server-side Anthropic errors
        let orKey = Self.effectiveOpenRouterKey
        if !orKey.isEmpty && isOpenRouterFallbackStatus(status) {
            return try await askViaOpenRouter(
                prompt: prompt, screenshot: screenshot, system: system,
                model: resolvedModel, maxTokens: maxTokens, orKey: orKey
            )
        }

        let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw MiraError.api(msg)
    }

    // UserDefaults key takes precedence over the compiled AppSecrets constant,
    // so a key entered in Settings is used without a recompile.
    static var effectiveOpenRouterKey: String {
        let saved = UserDefaults.standard.string(forKey: "mira_openrouter_key") ?? ""
        return saved.isEmpty ? AppSecrets.openRouterAPIKey : saved
    }

    private func isOpenRouterFallbackStatus(_ code: Int) -> Bool {
        [429, 503, 529].contains(code)
    }

    private func openRouterModelId(from anthropicId: String) -> String {
        switch anthropicId {
        case "claude-haiku-4-5-20251001", "claude-haiku-4-5": return "anthropic/claude-haiku-4-5"
        case "claude-sonnet-4-6":                             return "anthropic/claude-sonnet-4-5"
        case "claude-opus-4-8":                               return "anthropic/claude-opus-4"
        default:
            let base = anthropicId.replacingOccurrences(
                of: #"-\d{8}$"#, with: "", options: .regularExpression)
            return base.hasPrefix("anthropic/") ? base : "anthropic/\(base)"
        }
    }

    private func askViaOpenRouter(
        prompt:     String,
        screenshot: NSImage?,
        system:     String,
        model:      String,
        maxTokens:  Int,
        orKey:      String
    ) async throws -> String {
        // System prompt is a regular message in OpenAI-compatible format.
        var messages: [ORMessage] = [
            ORMessage(role: "system", content: .string(system))
        ]
        // User content — plain string unless an image is attached.
        if let img = screenshot, let b64 = img.pngBase64() {
            messages.append(ORMessage(role: "user", content: .parts([
                .image(b64, "image/png"),
                .text(prompt)
            ])))
        } else {
            messages.append(ORMessage(role: "user", content: .string(prompt)))
        }

        let orModel = openRouterModelId(from: model)
        let body = ORRequest(model: orModel, max_tokens: maxTokens, messages: messages)

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(orKey)",   forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("https://mira.app",  forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Mira",              forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = max(120, Double(maxTokens) / 40)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api("OpenRouter: \(msg)")
        }
        return try JSONDecoder().decode(ORResponse.self, from: data).text
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
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",    forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await MiraBackend.proxyData(for: req)
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
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await MiraBackend.proxyData(for: req)
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
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",        forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",  forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await MiraBackend.proxyData(for: req)
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

    // MARK: - Streaming (ported from farzaa/clicky ClaudeAPI.analyzeImageStreaming, MIT)

    /// Streams a Claude response, calling `onChunk` on the main actor as each text
    /// delta arrives. Returns the full accumulated text when the stream completes.
    ///
    /// Usage: UI layers call this and update a @Published var with each chunk for
    /// progressive text rendering — identical to how HeyClicky's response overlay works.
    func askStreaming(
        prompt: String,
        screenshot: NSImage? = nil,
        system: String = MiraPrompts.system,
        modelOverride: String? = nil,
        maxTokensOverride: Int? = nil,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var content: [[String: Any]] = []
        if let img = screenshot, let b64 = img.pngBase64() {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png", "data": b64]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let resolvedModel = modelOverride ?? model
        let maxTokens = maxTokensOverride ?? (screenshot != nil ? 800 : 512)

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = max(120, Double(maxTokens) / 40)

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.default
            c.urlCache = nil; c.httpCookieStorage = nil; return c
        }())
        let (byteStream, response) = try await MiraBackend.proxyBytes(for: req, using: session)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw MiraError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        var accumulated = ""
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            guard json != "[DONE]" else { break }
            guard let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["type"] as? String) == "content_block_delta",
                  let delta = payload["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let chunk = delta["text"] as? String else { continue }
            accumulated += chunk
            let current = accumulated
            await onChunk(current)
        }
        return accumulated
    }

    /// Streaming ask with a PRE-ENCODED image (caller controls format + size). The
    /// NSImage `askStreaming` PNG-encodes at full Retina resolution, which for a
    /// screen capture is ~14 MB base64 → over Anthropic's 5 MB/image cap → HTTP 400.
    /// The draw-on-screen path passes a downscaled JPEG through here instead.
    func askStreaming(
        prompt: String,
        imageBase64: String,
        imageMediaType: String = "image/jpeg",
        system: String = MiraPrompts.system,
        maxTokensOverride: Int? = nil,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": imageMediaType, "data": imageBase64]],
            ["type": "text", "text": prompt]
        ]
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokensOverride ?? 800,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.default
            c.urlCache = nil; c.httpCookieStorage = nil; return c
        }())
        let (byteStream, response) = try await MiraBackend.proxyBytes(for: req, using: session)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw MiraError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        var accumulated = ""
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            guard json != "[DONE]" else { break }
            guard let data = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["type"] as? String) == "content_block_delta",
                  let delta = payload["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let chunk = delta["text"] as? String else { continue }
            accumulated += chunk
            await onChunk(accumulated)
        }
        return accumulated
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
    static var system: String {
        var base = """
        You are Mira, a screen-aware Mac assistant. Be concise and direct — lead with the answer, no preamble.
        When asked to find something on screen, locate it precisely.
        Always confirm before any externally visible action (send email, create event, post, etc).
        Keep replies under 80 words.
        """
        // Inject active skill context (reads from nonisolated cache)
        let skillContext = SkillStore.cachedContext
        if !skillContext.isEmpty { base += skillContext }
        // Inject the imported user profile (personal-knowledge plane, local only)
        let userContext = UserKnowledgeStore.cachedContext
        if !userContext.isEmpty { base += userContext }
        // Inject connected integration context (reads from nonisolated cache)
        let integrationCtx = IntegrationContextService.cachedContext
        if !integrationCtx.isEmpty { base += integrationCtx }
        // Inject frontmost-app context (reads from nonisolated cache)
        if let appCtx = AppContextService.cachedContext { base += "\n\n" + appCtx }
        // Inject agent folder so all file output lands in the configured location
        let agentFolder = UserDefaults.standard.string(forKey: "mira_agent_folder")
            ?? (NSHomeDirectory() + "/Desktop/Mira")
        base += "\n\nDefault output folder: \(agentFolder) — save any generated files here unless the user specifies a different path."
        if UserDefaults.standard.bool(forKey: "mira_cat_mode") {
            base += "\nYou are also a cat. Occasionally add cat mannerisms: end sentences with ✿ or 🐾, use 'purrr' for emphasis, refer to yourself as Mira-chan. Keep it subtle — 1 in 4 responses max."
        }
        return base
    }

    // Voice-optimised prompt for the Realtime API — short, spoken, no markdown.
    static var realtimeSystem: String {
        let isCat = UserDefaults.standard.bool(forKey: "mira_cat_mode")
        let catSuffix = isCat ? " You are also a cat: occasionally purr, add 'nyaa' for delight, sign off with 🐾. Subtle, max 1 in 4." : ""
        return realtimeSystemBase + catSuffix
    }
    private static let realtimeSystemBase = """
    You are Mira, a screen-aware Mac assistant speaking out loud. Keep responses under 40 words. \
    You are speaking, not writing — no markdown, no bullet points, no lists. Lead with the answer. \
    Be direct and conversational. Confirm before any externally visible action (send email, create event, post). \
    You may call multiple tools in sequence within a single response before speaking. \
    A screenshot of the user's screen accompanies each spoken turn — use it to answer questions about \
    what they're looking at, and reference what you actually see. \
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
    Use run_shell_command for fast silent operations: reading files, system info, git status, quick one-liners. Never use it for installs or builds. \
    Use run_in_terminal when the user should see the command running: brew installs, npm/pip installs, builds, git clones, long scripts. It always opens a new Terminal window. \
    For multi-step terminal tasks (e.g. install Homebrew then ffmpeg), pass a single chained command to run_in_terminal using && so steps run in sequence — end the chain with && say "Done — [what was installed]" so the user hears completion. \
    Use set_volume to change the Mac's volume. \
    Use type_text to type into the currently focused app (requires Accessibility permission). \
    POINTING: When you tell the user where to look, click, or find something on screen, \
    append <point x=N y=N> at the very end of your response (after all spoken words), \
    where x and y are the UI element's position as fractions of screen width/height from the top-left (0.0–1.0). \
    Example: "Click the red button in the top-right corner <point x=0.91 y=0.04>". \
    Only use this tag when referencing a specific on-screen element location — never for abstract answers. \
    ABOUT YOURSELF: You are the Mira app — a notch island at the top of the screen. \
    Your own options live in Mira's Settings tab (the gear icon in the expanded island): \
    voice selection with previews, accent color, microphone, shortcuts, always-on listening, and integrations. \
    When asked how to change your voice, your color, or your settings, point to Mira's Settings — \
    never System Settings, which does not control you.
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

    // MARK: - Agent mode (full behavior contract, used for complex agent tasks)

    static var agentMode: String {
        let agentFolder = UserDefaults.standard.string(forKey: "mira_agent_folder")
            ?? (NSHomeDirectory() + "/Desktop/Mira")
        let skillContext = SkillStore.cachedContext
        let integrationCtx = IntegrationContextService.cachedContext
        var base = """
        You are Mira, an autonomous Mac AI assistant running an agent session.

        Environment:
        - You run inside Mira's macOS notch island shell
        - Screenshots attached to messages show the user's current desktop context
        - The user's default output folder is \(agentFolder) — save generated files there unless specified otherwise
        - Composio-backed integrations may be available via the agent service when connected
        - Computer Use (mcp__computer-use__*) is available for native macOS GUI automation
        - Codex CLI and Claude Code CLI are available for coding tasks when installed
        - Python skills (run_python_skill) handle: maps, obsidian, polymarket, PDF, DOCX, PPTX, spreadsheet, YouTube, OCR, iMessage, Reminders, Notes, Find My, diagrams
        - Screenshots and the focused app are context, not route selection — prefer structured APIs over GUI automation unless the user explicitly asks to click/type/use the visible interface

        Workflow routing (choose narrowest capable path):
        - Use clicky-artifacts / file management for opening, revealing, finding, exporting, renaming, or organizing generated files — always return an absolute path
        - Use research-report for web/source research, competitor briefs, market summaries, and PDF/MD/DOCX artifacts
        - Use repo-operator for GitHub, local git, PRs, commits, CI, code review, and repo setup
        - Use email-assistant for drafting, replies, triage, and outreach — always draft first and require explicit send approval
        - Use google-workspace via Composio for Gmail read/search, Calendar, Drive, Docs, and Sheets when connected
        - Use dev-setup-doctor for Codex, MCP, API keys, terminal, localhost, npm/node/python, and environment problems
        - Use build-preview for websites, web apps, dashboards, landing pages, frontend UI, and local preview loops
        - Use creative-studio to route broad creative work to the best available medium; provider-backed image/video/slide generation is not available — offer document or frontend alternative instead
        - Use computer-use (cua-driver contract) for native macOS app GUI automation and last-mile browser UI tasks only — not for research, API work, or file work

        Behavior contracts:
        - For any Composio write or externally visible mutation: use exact tool schema key names, verify the result with a read-back before claiming done
        - For Gmail/email: draft first, show recipient/subject/body summary, require explicit "send it" approval before sending
        - For calendar events: show summary before creating; never delete without confirmation
        - For Computer Use: snapshot → act with most specific tool → verify afterward; never steal focus; stop before form submit, send, payment, delete, account changes
        - For Codex CLI: always use pty=true and a git-initialized workdir; use --full-auto for building; background + process poll for long tasks
        - For Claude Code CLI: use -p flag for headless/print mode; always set --max-turns to prevent runaway loops
        - For multi-MCP / multi-app workflows: identify apps and operations first, check tool coverage once, read before write, carry stable IDs between calls, narrow broad results

        macOS file access (avoid permission-prompt storms):
        - Desktop, Documents, Downloads, iCloud Drive, Pictures, Movies, and Music are OS-protected — each is its own permission prompt
        - Default to the agent folder (\(agentFolder)) which needs no prompt
        - Before touching a personal folder, confirm it is the only folder needed — never scan multiple protected roots to locate a file
        - If unsure which folder a file is in, ask the user rather than probing multiple locations

        Style:
        - Sound confident, active, and direct
        - Prefer action over description when the request is clear
        - Keep commentary brief and milestone-based while work is in progress
        - Give a concise final answer that summarises the outcome and includes any file paths
        - When blocked, name the exact tool, permission, or capability that is missing
        """
        if !skillContext.isEmpty { base += skillContext }
        let userContext = UserKnowledgeStore.cachedContext
        if !userContext.isEmpty { base += userContext }
        if !integrationCtx.isEmpty { base += integrationCtx }
        return base
    }

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
    case notSignedIn
    case limitReached

    var errorDescription: String? {
        switch self {
        case .api(let m): return "API error: \(m)"
        case .noKey: return "Add your Claude API key in Settings."
        case .notSignedIn: return "Sign in to use Mira."
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
