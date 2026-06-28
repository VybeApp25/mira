import AppKit

@MainActor
final class StripePurchaseService {
    static let shared = StripePurchaseService()
    private init() {}

    enum PurchaseError: Error, LocalizedError {
        case notSignedIn
        case noSubscription
        case serverError(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn:       return "Sign in to upgrade."
            case .noSubscription:    return "No active subscription to manage."
            case .serverError(let m): return m
            }
        }
    }

    // Opens Stripe Checkout in the default browser for the given plan.
    func startCheckout(plan: SubscriptionPlan) async throws {
        guard plan == .pro || plan == .ultra else { return }

        let jwt = SupabaseService.cachedAccessToken
        guard !jwt.isEmpty else { throw PurchaseError.notSignedIn }

        let url = URL(string: "\(AppSecrets.supabaseURL)/functions/v1/stripe-checkout")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let plan: String }
        let planName = plan == .ultra ? "ultra" : "pro"
        req.httpBody = try JSONEncoder().encode(Body(plan: planName))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Purchase unavailable."
            throw PurchaseError.serverError(msg)
        }

        guard let checkoutURL = (try? JSONDecoder().decode([String: String].self, from: data))?["url"],
              let url = URL(string: checkoutURL) else {
            throw PurchaseError.serverError("No checkout URL returned.")
        }

        NSWorkspace.shared.open(url)

        // Payment completes in the browser; the Stripe webhook then updates
        // profiles.plan. Poll so the in-app plan reflects the upgrade without a
        // restart (also refreshed on app re-activation by EntitlementService).
        EntitlementService.shared.pollForUpgrade(from: EntitlementService.shared.plan)
    }

    // Opens the Stripe Billing Portal so a paid user can update or cancel their
    // subscription. The customer id is resolved server-side from the user's JWT.
    func openBillingPortal() async throws {
        let jwt = SupabaseService.cachedAccessToken
        guard !jwt.isEmpty else { throw PurchaseError.notSignedIn }

        let url = URL(string: "\(AppSecrets.supabaseURL)/functions/v1/stripe-portal")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let err = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            if err == "no_subscription" { throw PurchaseError.noSubscription }
            throw PurchaseError.serverError(err ?? "Couldn't open the billing portal.")
        }
        guard let portalURL = (try? JSONDecoder().decode([String: String].self, from: data))?["url"],
              let open = URL(string: portalURL) else {
            throw PurchaseError.serverError("No portal URL returned.")
        }
        NSWorkspace.shared.open(open)

        // Plan may change in the portal (cancel/downgrade) — refresh on return.
        EntitlementService.shared.pollForUpgrade(from: EntitlementService.shared.plan)
    }
}
