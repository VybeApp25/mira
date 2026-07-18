// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let skillsPublishRequest = try SkillsPublishRequest(json)
//   let skillsPublishResponse = try SkillsPublishResponse(json)
//   let skillsPublishErrorResponse = try SkillsPublishErrorResponse(json)

import Foundation

// MARK: - SkillsPublishRequest
struct SkillsPublishRequest: Codable {
    /// Full SKILL.md content: a --- frontmatter block (must include at least `name:`,
    /// kebab-case, ^[a-z0-9][a-z0-9-]{1,60}$) followed by a closing --- and then the body (min
    /// 10 chars after trimming). Recognized frontmatter keys: name (required, becomes slug),
    /// title (becomes display name, falls back to slug), tagline/description (becomes tagline,
    /// truncated to 120 chars, tagline takes precedence if both present), category (one of
    /// Productivity/Engineering/Communication/Creative, defaults to Productivity if
    /// absent/invalid), icon (defaults to "sparkles").
    let markdown: String
}

// MARK: SkillsPublishRequest convenience initializers and mutators

extension SkillsPublishRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SkillsPublishRequest.self, from: data)
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
        markdown: String? = nil
    ) -> SkillsPublishRequest {
        return SkillsPublishRequest(
            markdown: markdown ?? self.markdown
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SkillsPublishResponse
struct SkillsPublishResponse: Codable {
    /// One-sentence moderation rationale from the Claude moderation call, truncated to 300
    /// chars. "moderation could not be completed" if the moderation call itself failed.
    let reason: String
    let slug: String
    /// approved = AI moderation verdict "approve", auto-listed immediately. rejected = verdict
    /// "reject". pending = verdict "review" (ambiguous, awaits human review) OR the
    /// ANTHROPIC_API_KEY secret was unset server-side (moderation unavailable falls back to
    /// pending, not a hard error).
    let status: SkillsPublishStatus
}

// MARK: SkillsPublishResponse convenience initializers and mutators

extension SkillsPublishResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SkillsPublishResponse.self, from: data)
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
        reason: String? = nil,
        slug: String? = nil,
        status: SkillsPublishStatus? = nil
    ) -> SkillsPublishResponse {
        return SkillsPublishResponse(
            reason: reason ?? self.reason,
            slug: slug ?? self.slug,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// approved = AI moderation verdict "approve", auto-listed immediately. rejected = verdict
/// "reject". pending = verdict "review" (ambiguous, awaits human review) OR the
/// ANTHROPIC_API_KEY secret was unset server-side (moderation unavailable falls back to
/// pending, not a hard error).
enum SkillsPublishStatus: String, Codable {
    case approved = "approved"
    case pending = "pending"
    case rejected = "rejected"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - SkillsPublishErrorResponse
struct SkillsPublishErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: SkillsPublishErrorCode
    /// Present alongside malformed_skill, invalid_name, slug_taken, insert_failed — a
    /// human-readable elaboration.
    let detail: String?
}

// MARK: SkillsPublishErrorResponse convenience initializers and mutators

extension SkillsPublishErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SkillsPublishErrorResponse.self, from: data)
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
        error: SkillsPublishErrorCode? = nil,
        detail: String?? = nil
    ) -> SkillsPublishErrorResponse {
        return SkillsPublishErrorResponse(
            error: error ?? self.error,
            detail: detail ?? self.detail
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum SkillsPublishErrorCode: String, Codable {
    case emptyBody = "empty_body"
    case insertFailed = "insert_failed"
    case invalidMarkdown = "invalid_markdown"
    case invalidName = "invalid_name"
    case malformedSkill = "malformed_skill"
    case methodNotAllowed = "method_not_allowed"
    case slugTaken = "slug_taken"
    case unauthenticated = "unauthenticated"
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
