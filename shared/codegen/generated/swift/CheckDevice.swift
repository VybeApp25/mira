// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let checkDeviceRequest = try CheckDeviceRequest(json)
//   let checkDeviceResponse = try CheckDeviceResponse(json)
//   let checkDeviceErrorResponse = try CheckDeviceErrorResponse(json)

import Foundation

// MARK: - CheckDeviceRequest
struct CheckDeviceRequest: Codable {
    let deviceHash: String

    enum CodingKeys: String, CodingKey {
        case deviceHash = "device_hash"
    }
}

// MARK: CheckDeviceRequest convenience initializers and mutators

extension CheckDeviceRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CheckDeviceRequest.self, from: data)
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
        deviceHash: String? = nil
    ) -> CheckDeviceRequest {
        return CheckDeviceRequest(
            deviceHash: deviceHash ?? self.deviceHash
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - CheckDeviceResponse
struct CheckDeviceResponse: Codable {
    /// True if no free-tier account currently owns this device_hash. false-y/absent
    /// count-mismatch defaults to true (fail-open on a DB error is NOT the behavior here — a
    /// db_error is returned as an explicit error instead, see error schema).
    let available: Bool
}

// MARK: CheckDeviceResponse convenience initializers and mutators

extension CheckDeviceResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CheckDeviceResponse.self, from: data)
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
        available: Bool? = nil
    ) -> CheckDeviceResponse {
        return CheckDeviceResponse(
            available: available ?? self.available
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
// MARK: - CheckDeviceErrorResponse
struct CheckDeviceErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    let error: CheckDeviceErrorCode
}

// MARK: CheckDeviceErrorResponse convenience initializers and mutators

extension CheckDeviceErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(CheckDeviceErrorResponse.self, from: data)
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
        error: CheckDeviceErrorCode? = nil
    ) -> CheckDeviceErrorResponse {
        return CheckDeviceErrorResponse(
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

enum CheckDeviceErrorCode: String, Codable {
    case dbError = "db_error"
    case deviceHashRequired = "device_hash required"
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
