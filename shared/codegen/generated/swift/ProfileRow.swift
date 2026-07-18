// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let profileRow = try ProfileRow(json)

import Foundation

/// public.profiles row shape, read via PostgREST (e.g. GET /rest/v1/profiles?select=plan,
/// confirmed from Mira/Services/EntitlementService.swift's fetchAndApplyPlan()). Confirmed
/// columns come from supabase/migrations/20260614120000_secrets_proxy.sql (user_id, plan,
/// stripe_customer_id, updated_at), 20260625120000_stripe_subscription.sql
/// (stripe_subscription_id), and 20260626120000_device_lock_and_spend_alarm.sql
/// (device_id_hash). RLS restricts a signed-in user to SELECT on their own row only
/// (auth.uid() = user_id); there is no user-facing INSERT/UPDATE policy — every write
/// happens through a service-role Edge Function (stripe-webhook for
/// plan/stripe_customer_id/stripe_subscription_id; register-device for device_id_hash).
// MARK: - ProfileRow
struct ProfileRow: Codable {
    /// SHA-256(hardware serial + persisted random UUID). A partial unique index enforces at most
    /// one device_id_hash per free-tier account; paid accounts are exempt. See
    /// SECURITY_AND_PRIVACY.md for the Windows-equivalent fingerprint scheme this needs.
    let deviceIDHash: String?
    /// Server-side source of truth for entitlement. EntitlementService.swift's client-side cache
    /// is UX-only and must never be trusted for authorization decisions.
    let plan: ProfilePlan
    let stripeCustomerID, stripeSubscriptionID: String?
    let updatedAt: Date?
    let userID: String

    enum CodingKeys: String, CodingKey {
        case deviceIDHash = "device_id_hash"
        case plan
        case stripeCustomerID = "stripe_customer_id"
        case stripeSubscriptionID = "stripe_subscription_id"
        case updatedAt = "updated_at"
        case userID = "user_id"
    }
}

// MARK: ProfileRow convenience initializers and mutators

extension ProfileRow {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(ProfileRow.self, from: data)
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
        deviceIDHash: String?? = nil,
        plan: ProfilePlan? = nil,
        stripeCustomerID: String?? = nil,
        stripeSubscriptionID: String?? = nil,
        updatedAt: Date?? = nil,
        userID: String? = nil
    ) -> ProfileRow {
        return ProfileRow(
            deviceIDHash: deviceIDHash ?? self.deviceIDHash,
            plan: plan ?? self.plan,
            stripeCustomerID: stripeCustomerID ?? self.stripeCustomerID,
            stripeSubscriptionID: stripeSubscriptionID ?? self.stripeSubscriptionID,
            updatedAt: updatedAt ?? self.updatedAt,
            userID: userID ?? self.userID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// Server-side source of truth for entitlement. EntitlementService.swift's client-side cache
/// is UX-only and must never be trusted for authorization decisions.
enum ProfilePlan: String, Codable {
    case free = "free"
    case pro = "pro"
    case ultra = "ultra"
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
