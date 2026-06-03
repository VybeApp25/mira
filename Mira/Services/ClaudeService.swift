import Foundation
import AppKit

class ClaudeService {
    private let apiKey: String
    private let model = "claude-haiku-4-5-20251001"
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

    func ask(prompt: String, screenshot: NSImage? = nil, system: String = MiraPrompts.system) async throws -> String {
        var content: [APIContent] = []
        if let img = screenshot, let b64 = img.pngBase64() {
            content.append(.image(b64, "image/png"))
        }
        content.append(.text(prompt))

        let body = APIRequest(model: model, max_tokens: 400, system: system,
                              messages: [APIMessage(role: "user", content: content)])

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api(msg)
        }
        return try JSONDecoder().decode(APIResponse.self, from: data).text
    }

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
    Use get_current_context whenever the user references something on screen, selected text, or clipboard.
    """

    static let vision = """
    You are a precise UI element locator. Return only a JSON object with pixel coordinates.
    Analyze the screenshot carefully. Coordinates are from the top-left corner of the image.
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
