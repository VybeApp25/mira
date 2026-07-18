// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let stripeCheckoutRequest = try StripeCheckoutRequest(json)
//   let stripeCheckoutResponse = try StripeCheckoutResponse(json)
//   let stripeCheckoutErrorResponse = try StripeCheckoutErrorResponse(json)

import Foundation

// MARK: - StripeCheckoutRequest
struct StripeCheckoutRequest: Codable {
    /// Any value other than "ultra" is treated as "pro" server-side (the function does plan ===
    /// "ultra" ? PRICE_ULTRA : PRICE_PRO with no explicit validation error for a bad value) —
    /// this is a looseness in the current source, not a documented contract guarantee.
    let plan: StripeCheckoutPlan
}

// MARK: StripeCheckoutRequest convenience initializers and mutators

extension StripeCheckoutRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StripeCheckoutRequest.self, from: data)
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
        plan: StripeCheckoutPlan? = nil
    ) -> StripeCheckoutRequest {
        return StripeCheckoutRequest(
            plan: plan ?? self.plan
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Any value other than "ultra" is treated as "pro" server-side (the function does plan ===
/// "ultra" ? PRICE_ULTRA : PRICE_PRO with no explicit validation error for a bad value) —
/// this is a looseness in the current source, not a documented contract guarantee.
enum StripeCheckoutPlan: String, Codable {
    case pro = "pro"
    case ultra = "ultra"
}

// MARK: - StripeCheckoutResponse
struct StripeCheckoutResponse: Codable {
    /// Stripe-hosted Checkout session URL.
    let url: String
}

// MARK: StripeCheckoutResponse convenience initializers and mutators

extension StripeCheckoutResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StripeCheckoutResponse.self, from: data)
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
        url: String? = nil
    ) -> StripeCheckoutResponse {
        return StripeCheckoutResponse(
            url: url ?? self.url
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
// MARK: - StripeCheckoutErrorResponse
struct StripeCheckoutErrorResponse: Codable {
    /// Machine-readable error code. Observed values across functions include: unauthenticated,
    /// upgrade_required, quota_exceeded, voice_quota_exceeded, model_not_allowed,
    /// voice_not_allowed, invalid_body, method_not_allowed, path_not_allowed, device_hash
    /// required, device_already_registered, no_subscription, slug_taken, invalid_name,
    /// invalid_markdown, malformed_skill, empty_body, query_failed, insert_failed, and a handful
    /// of "<PROVIDER>_SECRET_KEY secret not set" / "stripe_error" / "spotify_token_failed"
    /// strings. Treat this as an open string enum, not closed — new functions may introduce new
    /// codes.
    ///
    /// Either unauthenticated (thrown by requireUser) or Stripe's own session.error.message
    /// forwarded through on a Stripe API failure (400).
    let error: String
}

// MARK: StripeCheckoutErrorResponse convenience initializers and mutators

extension StripeCheckoutErrorResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(StripeCheckoutErrorResponse.self, from: data)
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
    ) -> StripeCheckoutErrorResponse {
        return StripeCheckoutErrorResponse(
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
