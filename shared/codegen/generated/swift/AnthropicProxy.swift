// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let anthropicProxyRequest = try AnthropicProxyRequest(json)
//   let anthropicProxyErrorResponse = try AnthropicProxyErrorResponse(json)

import Foundation

/// Passthrough of the Anthropic Messages API request body. Only `model` and `max_tokens` are
/// inspected server-side; everything else (messages, system, tools, tool_choice, stream,
/// metadata, etc.) is forwarded as-is to api.anthropic.com/v1/messages.
// MARK: - AnthropicProxyRequest
struct AnthropicProxyRequest: Codable {
    /// Capped server-side to a per-plan ceiling (free: 1500, pro: 8000, ultra: 16000) via
    /// Math.min — the client's requested value is silently reduced, never rejected, if it
    /// exceeds the cap.
    let maxTokens: Int?
    /// Server-side allowlist (ALLOWED_MODELS in the function) — any other value is rejected with
    /// model_not_allowed. This list is a snapshot as of this audit and WILL drift as Mira adopts
    /// new models; treat it as a live value to re-derive from source at codegen time, not a
    /// frozen constant.
    let model: AnthropicProxyModel
    /// When true, the response is Content-Type: text/event-stream, metered by tapping
    /// message_start/message_delta usage fields inline. When false/absent, the response is
    /// application/json, metered from the final usage block.
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case model, stream
    }
}

// MARK: AnthropicProxyRequest convenience initializers and mutators

extension AnthropicProxyRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AnthropicProxyRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        maxTokens: Int?? = nil,
        model: AnthropicProxyModel? = nil,
        stream: Bool?? = nil
    ) -> AnthropicProxyRequest {
        return AnthropicProxyRequest(
            maxTokens: maxTokens ?? self.maxTokens,
            model: model ?? self.model,
            stream: stream ?? self.stream
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Server-side allowlist (ALLOWED_MODELS in the function) — any other value is rejected with
/// model_not_allowed. This list is a snapshot as of this audit and WILL drift as Mira adopts
/// new models; treat it as a live value to re-derive from source at codegen time, not a
/// frozen constant.
enum AnthropicProxyModel: String, Codable {
    case claudeFable5 = "claude-fable-5"
    case claudeHaiku45 = "claude-haiku-4-5"
    case claudeHaiku4520251001 = "claude-haiku-4-5-20251001"
    case claudeOpus48 = "claude-opus-4-8"
    case claudeSonnet46 = "claude-sonnet-4-6"
    case claudeSonnet5 = "claude-sonnet-5"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - AnthropicProxyErrorResponse
struct AnthropicProxyErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: AnthropicProxyErrorCode
    /// Present only alongside error=model_not_allowed; echoes the rejected model name.
    let model: String?
}

// MARK: AnthropicProxyErrorResponse convenience initializers and mutators

extension AnthropicProxyErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(AnthropicProxyErrorResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        error: AnthropicProxyErrorCode? = nil,
        model: String?? = nil
    ) -> AnthropicProxyErrorResponse {
        return AnthropicProxyErrorResponse(
            error: error ?? self.error,
            model: model ?? self.model
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum AnthropicProxyErrorCode: String, Codable {
    case anthropicAPIKEYSecretNotSet = "ANTHROPIC_API_KEY secret not set"
    case invalidBody = "invalid_body"
    case methodNotAllowed = "method_not_allowed"
    case modelNotAllowed = "model_not_allowed"
    case quotaExceeded = "quota_exceeded"
    case unauthenticated = "unauthenticated"
    case upgradeRequired = "upgrade_required"
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}
