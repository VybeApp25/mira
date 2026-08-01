// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let openAITTSProxyRequest = try OpenAITTSProxyRequest(json)
//   let openAITTSProxySuccessResponse = try OpenAITTSProxySuccessResponse(json)
//   let openAITTSProxyErrorResponse = try OpenAITTSProxyErrorResponse(json)

import Foundation

// MARK: - OpenAITTSProxyRequest
struct OpenAITTSProxyRequest: Codable {
    /// Server-side allowlist (ALLOWED_VOICES) mirroring MiraVoice in the Swift client.
    let voice: OpenAITTSProxyVoice
}

// MARK: OpenAITTSProxyRequest convenience initializers and mutators

extension OpenAITTSProxyRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OpenAITTSProxyRequest.self, from: data)
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
        voice: OpenAITTSProxyVoice? = nil
    ) -> OpenAITTSProxyRequest {
        return OpenAITTSProxyRequest(
            voice: voice ?? self.voice
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Server-side allowlist (ALLOWED_VOICES) mirroring MiraVoice in the Swift client.
enum OpenAITTSProxyVoice: String, Codable {
    case alloy = "alloy"
    case ash = "ash"
    case ballad = "ballad"
    case cedar = "cedar"
    case coral = "coral"
    case echo = "echo"
    case marin = "marin"
    case sage = "sage"
    case shimmer = "shimmer"
    case verse = "verse"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - OpenAITTSProxyErrorResponse
struct OpenAITTSProxyErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: OpenAittsProxy
    /// Present only alongside error=voice_not_allowed; echoes the rejected voice name.
    let voice: String?
}

// MARK: OpenAITTSProxyErrorResponse convenience initializers and mutators

extension OpenAITTSProxyErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OpenAITTSProxyErrorResponse.self, from: data)
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
        error: OpenAittsProxy? = nil,
        voice: String?? = nil
    ) -> OpenAITTSProxyErrorResponse {
        return OpenAITTSProxyErrorResponse(
            error: error ?? self.error,
            voice: voice ?? self.voice
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// The actual HTTP response is a raw audio/mpeg byte stream, not JSON — this schema entry
/// exists only to document that binary contract for a codegen target that needs an explicit
/// type (most HTTP client generators treat this endpoint as returning a byte array / Data /
/// Stream, not a decoded model type).
enum OpenAittsProxy: String, Codable {
    case methodNotAllowed = "method_not_allowed"
    case openaiAPIKEYSecretNotSet = "OPENAI_API_KEY secret not set"
    case quotaExceeded = "quota_exceeded"
    case unauthenticated = "unauthenticated"
    case upgradeRequired = "upgrade_required"
    case voiceNotAllowed = "voice_not_allowed"
}

typealias OpenAITTSProxySuccessResponse = String

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
