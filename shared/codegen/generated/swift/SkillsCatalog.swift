// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let skillsCatalogResponse = try SkillsCatalogResponse(json)
//   let communitySkillRow = try CommunitySkillRow(json)
//   let skillsCatalogErrorResponse = try SkillsCatalogErrorResponse(json)

import Foundation

// MARK: - SkillsCatalogResponse
struct SkillsCatalogResponse: Codable {
    let skills: [CommunitySkillRow]
}

// MARK: SkillsCatalogResponse convenience initializers and mutators

extension SkillsCatalogResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SkillsCatalogResponse.self, from: data)
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
        skills: [CommunitySkillRow]? = nil
    ) -> SkillsCatalogResponse {
        return SkillsCatalogResponse(
            skills: skills ?? self.skills
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// A single community_skills row as exposed by this endpoint
/// (status/author_id/moderation_reason are deliberately NOT selected here — those are
/// internal-only fields visible to the author via a different query path, not this public
/// catalog read).
// MARK: - CommunitySkillRow
struct CommunitySkillRow: Codable {
    let authorHandle: String
    /// The literal text injected into Claude's system prompt when this skill is activated.
    /// Stored in-row (no storage bucket).
    let body: String
    let category: CommunitySkillCategory
    let createdAt: Date
    let downloads: Int
    let icon, name: String
    let slug: String
    let tagline: String

    enum CodingKeys: String, CodingKey {
        case authorHandle = "author_handle"
        case body, category
        case createdAt = "created_at"
        case downloads, icon, name, slug, tagline
    }
}

// MARK: CommunitySkillRow convenience initializers and mutators

extension CommunitySkillRow {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CommunitySkillRow.self, from: data)
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
        authorHandle: String? = nil,
        body: String? = nil,
        category: CommunitySkillCategory? = nil,
        createdAt: Date? = nil,
        downloads: Int? = nil,
        icon: String? = nil,
        name: String? = nil,
        slug: String? = nil,
        tagline: String? = nil
    ) -> CommunitySkillRow {
        return CommunitySkillRow(
            authorHandle: authorHandle ?? self.authorHandle,
            body: body ?? self.body,
            category: category ?? self.category,
            createdAt: createdAt ?? self.createdAt,
            downloads: downloads ?? self.downloads,
            icon: icon ?? self.icon,
            name: name ?? self.name,
            slug: slug ?? self.slug,
            tagline: tagline ?? self.tagline
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

enum CommunitySkillCategory: String, Codable {
    case communication = "Communication"
    case creative = "Creative"
    case engineering = "Engineering"
    case productivity = "Productivity"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - SkillsCatalogErrorResponse
struct SkillsCatalogErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: SkillsCatalogErrorCode
    let detail: String?
}

// MARK: SkillsCatalogErrorResponse convenience initializers and mutators

extension SkillsCatalogErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SkillsCatalogErrorResponse.self, from: data)
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
        error: SkillsCatalogErrorCode? = nil,
        detail: String?? = nil
    ) -> SkillsCatalogErrorResponse {
        return SkillsCatalogErrorResponse(
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

enum SkillsCatalogErrorCode: String, Codable {
    case queryFailed = "query_failed"
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
