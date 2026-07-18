// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let spotifySearchRequest = try SpotifySearchRequest(json)
//   let spotifySearchResponse = try SpotifySearchResponse(json)
//   let spotifySearchErrorResponse = try SpotifySearchErrorResponse(json)

import Foundation

/// Provide either `query` (free text) or `track`/`artist` (used together as Spotify field
/// filters `track:X artist:Y` for a more precise match, or individually as plain search
/// terms). At least one of query/track/artist must resolve to a non-empty search string or
/// the function returns 'missing query'.
// MARK: - SpotifySearchRequest
struct SpotifySearchRequest: Codable {
    let artist, query, track: String?
}

// MARK: SpotifySearchRequest convenience initializers and mutators

extension SpotifySearchRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpotifySearchRequest.self, from: data)
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
        artist: String?? = nil,
        query: String?? = nil,
        track: String?? = nil
    ) -> SpotifySearchRequest {
        return SpotifySearchRequest(
            artist: artist ?? self.artist,
            query: query ?? self.query,
            track: track ?? self.track
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - SpotifySearchResponse
struct SpotifySearchResponse: Codable {
    /// Comma-joined artist names.
    let artist: String
    let name: String
    /// Spotify URI, e.g. spotify:track:...
    let uri: String
}

// MARK: SpotifySearchResponse convenience initializers and mutators

extension SpotifySearchResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpotifySearchResponse.self, from: data)
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
        artist: String? = nil,
        name: String? = nil,
        uri: String? = nil
    ) -> SpotifySearchResponse {
        return SpotifySearchResponse(
            artist: artist ?? self.artist,
            name: name ?? self.name,
            uri: uri ?? self.uri
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - SpotifySearchErrorResponse
struct SpotifySearchErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: SpotifySearchErrorCode
    /// Present only alongside error=no_match; echoes the resolved search string.
    let query: String?
    /// Present only alongside spotify_token_failed/spotify_search_failed; echoes the upstream
    /// Spotify HTTP status.
    let status: Int?
}

// MARK: SpotifySearchErrorResponse convenience initializers and mutators

extension SpotifySearchErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SpotifySearchErrorResponse.self, from: data)
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
        error: SpotifySearchErrorCode? = nil,
        query: String?? = nil,
        status: Int?? = nil
    ) -> SpotifySearchErrorResponse {
        return SpotifySearchErrorResponse(
            error: error ?? self.error,
            query: query ?? self.query,
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

enum SpotifySearchErrorCode: String, Codable {
    case missingQuery = "missing query"
    case noMatch = "no_match"
    case spotifyCLIENTIDSPOTIFYCLIENTSECRETSecretNotSet = "SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET secret not set"
    case spotifySearchFailed = "spotify_search_failed"
    case spotifyTokenFailed = "spotify_token_failed"
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
