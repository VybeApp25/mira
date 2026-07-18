// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let supabaseSignUpRequest = try SupabaseSignUpRequest(json)

import Foundation

/// Request body Mira sends to Supabase GoTrue's POST /auth/v1/signup. Confirmed from
/// Mira/Services/SupabaseService.swift's signUp(email:password:name:). A 200 response with
/// no access_token means signup succeeded but email confirmation is pending (not an error) —
/// see SupabaseAuthResponse for the success shape, and note the client must treat 'no
/// session in the response' as a distinct, non-error outcome.
// MARK: - SupabaseSignUpRequest
struct SupabaseSignUpRequest: Codable {
    let data: DataClass
    let email, password: String
}

// MARK: SupabaseSignUpRequest convenience initializers and mutators

extension SupabaseSignUpRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(SupabaseSignUpRequest.self, from: data)
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
        data: DataClass? = nil,
        email: String? = nil,
        password: String? = nil
    ) -> SupabaseSignUpRequest {
        return SupabaseSignUpRequest(
            data: data ?? self.data,
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

// MARK: - DataClass
struct DataClass: Codable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

// MARK: DataClass convenience initializers and mutators

extension DataClass {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(DataClass.self, from: data)
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
        displayName: String? = nil
    ) -> DataClass {
        return DataClass(
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
