// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let reportVoiceUsageRequest = try ReportVoiceUsageRequest(json)
//   let reportVoiceUsageResponse = try ReportVoiceUsageResponse(json)

import Foundation

// MARK: - ReportVoiceUsageRequest
struct ReportVoiceUsageRequest: Codable {
    /// Session duration in seconds. Non-finite or <= 0 values are silently treated as 0 (still
    /// returns {status:"ok"}, no error). Clamped server-side to 3600 max.
    let seconds: Double?
}

// MARK: ReportVoiceUsageRequest convenience initializers and mutators

extension ReportVoiceUsageRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ReportVoiceUsageRequest.self, from: data)
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
        seconds: Double?? = nil
    ) -> ReportVoiceUsageRequest {
        return ReportVoiceUsageRequest(
            seconds: seconds ?? self.seconds
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - ReportVoiceUsageResponse
struct ReportVoiceUsageResponse: Codable {
    let status: ReportVoiceUsageStatus
}

// MARK: ReportVoiceUsageResponse convenience initializers and mutators

extension ReportVoiceUsageResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ReportVoiceUsageResponse.self, from: data)
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
        status: ReportVoiceUsageStatus? = nil
    ) -> ReportVoiceUsageResponse {
        return ReportVoiceUsageResponse(
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

enum ReportVoiceUsageStatus: String, Codable {
    case ok = "ok"
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
