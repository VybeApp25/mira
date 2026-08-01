// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let registerDeviceRequest = try RegisterDeviceRequest(json)
//   let registerDeviceResponse = try RegisterDeviceResponse(json)
//   let registerDeviceErrorResponse = try RegisterDeviceErrorResponse(json)

import Foundation

// MARK: - RegisterDeviceRequest
struct RegisterDeviceRequest: Codable {
    let deviceHash: String

    enum CodingKeys: String, CodingKey {
        case deviceHash = "device_hash"
    }
}

// MARK: RegisterDeviceRequest convenience initializers and mutators

extension RegisterDeviceRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RegisterDeviceRequest.self, from: data)
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
    ) -> RegisterDeviceRequest {
        return RegisterDeviceRequest(
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

// MARK: - RegisterDeviceResponse
struct RegisterDeviceResponse: Codable {
    let status: RegisterDeviceStatus
}

// MARK: RegisterDeviceResponse convenience initializers and mutators

extension RegisterDeviceResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RegisterDeviceResponse.self, from: data)
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
        status: RegisterDeviceStatus? = nil
    ) -> RegisterDeviceResponse {
        return RegisterDeviceResponse(
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

enum RegisterDeviceStatus: String, Codable {
    case ok = "ok"
}

/// Generic error envelope returned by every Mira Supabase Edge Function on failure
/// (4xx/5xx), confirmed by reading the json(...) helper in
/// supabase/functions/_shared/auth.ts and the equivalent inline helper duplicated in the
/// self-contained functions (spotify-config, spotify-search, skills-catalog,
/// skills-publish). Individual functions add extra fields on top of this base shape (see
/// each function's own schema) — this is the minimum guaranteed shape, not the exact shape.
// MARK: - RegisterDeviceErrorResponse
struct RegisterDeviceErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    ///
    /// device_already_registered is returned with HTTP 409, not the usual 400/401/402/429
    /// pattern used elsewhere.
    let error: RegisterDeviceErrorCode
}

// MARK: RegisterDeviceErrorResponse convenience initializers and mutators

extension RegisterDeviceErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(RegisterDeviceErrorResponse.self, from: data)
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
        error: RegisterDeviceErrorCode? = nil
    ) -> RegisterDeviceErrorResponse {
        return RegisterDeviceErrorResponse(
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

/// device_already_registered is returned with HTTP 409, not the usual 400/401/402/429
/// pattern used elsewhere.
enum RegisterDeviceErrorCode: String, Codable {
    case deviceAlreadyRegistered = "device_already_registered"
    case deviceHashRequired = "device_hash required"
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
