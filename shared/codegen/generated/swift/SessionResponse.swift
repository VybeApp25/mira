// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let supabaseAuthResponse = try SupabaseAuthResponse(json)

import Foundation

/// Response body from Supabase GoTrue's POST /auth/v1/token (grant_type=password |
/// refresh_token | id_token) and POST /auth/v1/signup when a session is issued immediately.
/// Confirmed from Mira/Services/SupabaseService.swift's private AuthResponse + SupabaseUser
/// structs (source of truth: Supabase GoTrue itself, not a Mira-authored contract — Mira
/// only decodes a subset of the full response). This is NOT a Mira Edge Function; it is
/// Supabase's own hosted auth API, called directly by the client with the anon key.
// MARK: - SupabaseAuthResponse
struct SupabaseAuthResponse: Codable {
    /// Short-lived JWT, ~1h expiry per SupabaseService.swift's auto-refresh comments.
    let accessToken: String
    /// Seconds until access_token expires.
    let expiresIn: Int
    /// Single-use — rotates on every refresh. SupabaseService.swift single-flights concurrent
    /// refreshes specifically to avoid rotating this twice.
    let refreshToken: String
    let tokenType: String
    let user: SupabaseAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case user
    }
}

// MARK: SupabaseAuthResponse convenience initializers and mutators

extension SupabaseAuthResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SupabaseAuthResponse.self, from: data)
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
        accessToken: String? = nil,
        expiresIn: Int? = nil,
        refreshToken: String? = nil,
        tokenType: String? = nil,
        user: SupabaseAuthUser? = nil
    ) -> SupabaseAuthResponse {
        return SupabaseAuthResponse(
            accessToken: accessToken ?? self.accessToken,
            expiresIn: expiresIn ?? self.expiresIn,
            refreshToken: refreshToken ?? self.refreshToken,
            tokenType: tokenType ?? self.tokenType,
            user: user ?? self.user
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Only the fields Mira's client actually decodes (id, email, user_metadata.display_name) —
/// GoTrue's real user object has more fields; this is a deliberate subset, not the full
/// upstream shape.
// MARK: - SupabaseAuthUser
struct SupabaseAuthUser: Codable {
    let email: String?
    let id: String
    /// Mixed-type bag (e.g. email_verified: bool alongside display_name: string) —
    /// SupabaseUser.swift decodes this via a nested container specifically because of the mixed
    /// types.
    let userMetadata: UserMetadata?

    enum CodingKeys: String, CodingKey {
        case email, id
        case userMetadata = "user_metadata"
    }
}

// MARK: SupabaseAuthUser convenience initializers and mutators

extension SupabaseAuthUser {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SupabaseAuthUser.self, from: data)
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
        email: String?? = nil,
        id: String? = nil,
        userMetadata: UserMetadata?? = nil
    ) -> SupabaseAuthUser {
        return SupabaseAuthUser(
            email: email ?? self.email,
            id: id ?? self.id,
            userMetadata: userMetadata ?? self.userMetadata
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Mixed-type bag (e.g. email_verified: bool alongside display_name: string) —
/// SupabaseUser.swift decodes this via a nested container specifically because of the mixed
/// types.
// MARK: - UserMetadata
struct UserMetadata: Codable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

// MARK: UserMetadata convenience initializers and mutators

extension UserMetadata {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(UserMetadata.self, from: data)
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
        displayName: String?? = nil
    ) -> UserMetadata {
        return UserMetadata(
            displayName: displayName ?? self.displayName
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
