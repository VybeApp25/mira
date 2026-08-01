// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let supabaseSignInRequest = try SupabaseSignInRequest(json)

import Foundation

/// Request body Mira sends to Supabase GoTrue's POST /auth/v1/token?grant_type=password.
/// Confirmed from Mira/Services/SupabaseService.swift's signIn(email:password:). Sent with
/// header apikey: <anon key> (public, not a secret).
// MARK: - SupabaseSignInRequest
struct SupabaseSignInRequest: Codable {
    let email, password: String
}

// MARK: SupabaseSignInRequest convenience initializers and mutators

extension SupabaseSignInRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SupabaseSignInRequest.self, from: data)
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
        email: String? = nil,
        password: String? = nil
    ) -> SupabaseSignInRequest {
        return SupabaseSignInRequest(
            email: email ?? self.email,
            password: password ?? self.password
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
