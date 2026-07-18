// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let mintRealtimeTokenRequest = try MintRealtimeTokenRequest(json)
//   let mintRealtimeTokenResponse = try MintRealtimeTokenResponse(json)
//   let mintRealtimeTokenErrorResponse = try MintRealtimeTokenErrorResponse(json)

import Foundation

// MARK: - MintRealtimeTokenRequest
struct MintRealtimeTokenRequest: Codable {
    /// Optional; defaults to "alloy" server-side if omitted. Not validated against an allowlist
    /// in this function (contrast with openai-tts-proxy, which does allowlist voices).
    let voice: String?
}

// MARK: MintRealtimeTokenRequest convenience initializers and mutators

extension MintRealtimeTokenRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MintRealtimeTokenRequest.self, from: data)
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
        voice: String?? = nil
    ) -> MintRealtimeTokenRequest {
        return MintRealtimeTokenRequest(
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

// MARK: - MintRealtimeTokenResponse
struct MintRealtimeTokenResponse: Codable {
    /// Unix timestamp; 0 if OpenAI's response omitted it.
    let expiresAt: Int
    /// Hardcoded server-side; not client-selectable today.
    let model: MintRealtimeTokenModel
    /// The ephemeral OpenAI Realtime client secret (payload.value from OpenAI's own
    /// /v1/realtime/client_secrets response). Empty string if OpenAI's response omitted it.
    let token: String

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
        case model, token
    }
}

// MARK: MintRealtimeTokenResponse convenience initializers and mutators

extension MintRealtimeTokenResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MintRealtimeTokenResponse.self, from: data)
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
        expiresAt: Int? = nil,
        model: MintRealtimeTokenModel? = nil,
        token: String? = nil
    ) -> MintRealtimeTokenResponse {
        return MintRealtimeTokenResponse(
            expiresAt: expiresAt ?? self.expiresAt,
            model: model ?? self.model,
            token: token ?? self.token
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum MintRealtimeTokenModel: String, Codable {
    case gptRealtime = "gpt-realtime"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - MintRealtimeTokenErrorResponse
struct MintRealtimeTokenErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    ///
    /// Either a string code (unauthenticated, upgrade_required, voice_quota_exceeded,
    /// OPENAI_API_KEY secret not set) OR, on an upstream OpenAI failure, the raw OpenAI error
    /// object forwarded as-is (the function does { error: payload } in that branch) — this
    /// field's shape genuinely varies by failure mode; treat as a union client-side rather than
    /// assuming it's always a string.
    let error: String
}

// MARK: MintRealtimeTokenErrorResponse convenience initializers and mutators

extension MintRealtimeTokenErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(MintRealtimeTokenErrorResponse.self, from: data)
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
        error: String? = nil
    ) -> MintRealtimeTokenErrorResponse {
        return MintRealtimeTokenErrorResponse(
            error: error ?? self.error
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
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
