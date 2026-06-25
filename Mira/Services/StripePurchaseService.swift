import AppKit

@MainActor
final class StripePurchaseService {
    static let shared = StripePurchaseService()
    private init() {}

    enum PurchaseError: Error, LocalizedError {
        case notSignedIn
        case serverError(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn:       return "Sign in to upgrade."
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
    }
}
