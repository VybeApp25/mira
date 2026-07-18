// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let openAITTSNarrationRequest = try OpenAITTSNarrationRequest(json)
//   let openAITTSNarrationSuccessResponse = try OpenAITTSNarrationSuccessResponse(json)
//   let openAITTSNarrationErrorResponse = try OpenAITTSNarrationErrorResponse(json)

import Foundation

// MARK: - OpenAITTSNarrationRequest
struct OpenAITTSNarrationRequest: Codable {
    /// The text to speak. Required and non-empty; rejected with input_required if blank,
    /// input_too_long if over 600 chars.
    let input: String
    /// Defaults to "marin" server-side if omitted (matches Mira's onboarding narrator voice).
    let voice: OpenAITTSNarrationVoice?
}

// MARK: OpenAITTSNarrationRequest convenience initializers and mutators

extension OpenAITTSNarrationRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OpenAITTSNarrationRequest.self, from: data)
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
        input: String? = nil,
        voice: OpenAITTSNarrationVoice?? = nil
    ) -> OpenAITTSNarrationRequest {
        return OpenAITTSNarrationRequest(
            input: input ?? self.input,
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

/// Defaults to "marin" server-side if omitted (matches Mira's onboarding narrator voice).
enum OpenAITTSNarrationVoice: String, Codable {
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
// MARK: - OpenAITTSNarrationErrorResponse
struct OpenAITTSNarrationErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: OpenAittsNarration
    /// Present only alongside error=input_too_long; echoes MAX_CHARS (600).
    let max: Int?
    let voice: String?
}

// MARK: OpenAITTSNarrationErrorResponse convenience initializers and mutators

extension OpenAITTSNarrationErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(OpenAITTSNarrationErrorResponse.self, from: data)
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
        error: OpenAittsNarration? = nil,
        max: Int?? = nil,
        voice: String?? = nil
    ) -> OpenAITTSNarrationErrorResponse {
        return OpenAITTSNarrationErrorResponse(
            error: error ?? self.error,
            max: max ?? self.max,
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

/// Raw audio/mpeg byte stream on success — same binary-response note as
/// OpenAITTSProxySuccessResponse.
enum OpenAittsNarration: String, Codable {
    case inputRequired = "input_required"
    case inputTooLong = "input_too_long"
    case methodNotAllowed = "method_not_allowed"
    case openaiAPIKEYNotSet = "OPENAI_API_KEY not set"
    case unauthenticated = "unauthenticated"
    case voiceNotAllowed = "voice_not_allowed"
}

typealias OpenAITTSNarrationSuccessResponse = String

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
