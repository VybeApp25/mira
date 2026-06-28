import Foundation
import AppKit

// MARK: - Supabase auth responses

private struct AuthResponse: Decodable {
    let accessToken:  String
    let tokenType:    String
    let expiresIn:    Int
    let refreshToken: String
    let user:         SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case tokenType    = "token_type"
        case expiresIn    = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}

struct SupabaseUser: Decodable {
    let id:    String
    let email: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
    // user_metadata mixes value types (e.g. email_verified: Bool), so it can't
    // decode as [String: String]. We only need display_name — pull it out of a
    // nested container and ignore everything else.
    private enum MetaKeys: String, CodingKey { case displayName = "display_name" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id    = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        if let meta = try? c.nestedContainer(keyedBy: MetaKeys.self, forKey: .userMetadata) {
            displayName = try? meta.decodeIfPresent(String.self, forKey: .displayName)
        } else {
            displayName = nil
        }
    }
}

// MARK: - Supabase session (stored in UserDefaults)

struct SupabaseSession: Codable {
    let accessToken:  String
    let refreshToken: String
    let userId:       String
    let email:        String?
    let displayName:  String?
    let expiresAt:    Date
}

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case invalidURL
    case network(Error)
    case serverError(Int, String)
    case decodingError(Error)
    case noSession

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "Invalid Supabase URL"
        case .network(let e):      return e.localizedDescription
        case .serverError(_, let msg): return msg
        case .decodingError(let e):return e.localizedDescription
        case .noSession:           return "Not signed in"
        }
    }
}

// MARK: - Service

@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    @Published private(set) var session: SupabaseSession? {
        didSet {
            Self.cachedAccessToken = session?.accessToken ?? ""
            scheduleAutoRefresh()
        }
    }

    // Thread-safe mirror of the current JWT so non-MainActor network call sites
    // (e.g. MiraBackend) can attach it without an actor hop. Updated on every
    // session change via the didSet above.
    nonisolated(unsafe) static var cachedAccessToken: String = ""

    private let baseURL = AppSecrets.supabaseURL
    private let anonKey = AppSecrets.supabaseAnonKey
    private let sessionKey = "mira_supabase_session"

    private init() {
        loadSession()
        observeSystemWake()
    }

    /// The access token expires ~1h after sign-in, and a run-loop `Timer` is
    /// suspended while the Mac sleeps — so a token that lapses overnight has nothing
    /// to renew it (`NSApplication.didBecomeActive` doesn't fire on wake, and a notch
    /// utility is rarely brought frontmost). Listen for the real wake signal and
    /// refresh immediately, before the next proxy/voice call can 401.
    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.ensureFreshToken() }
        }
    }

    var isSignedIn: Bool { session != nil }

    // MARK: - Sign In

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        let body: [String: String] = ["email": email, "password": password]
        let auth = try await post(
            path: "/auth/v1/token?grant_type=password",
            body: body,
            as: AuthResponse.self
        )
        let s = makeSession(from: auth)
        save(s)
        session = s
        PostHogService.shared.capture("auth_sign_in", properties: ["method": "email"])
        return s
    }

    // MARK: - Sign Up

    // Returns nil when signup succeeded but email confirmation is required.
    func signUp(email: String, password: String, name: String) async throws -> SupabaseSession? {
        guard let url = URL(string: baseURL + "/auth/v1/signup") else { throw SupabaseError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "data": ["display_name": name]
        ])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw SupabaseError.network(error) }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Server error"
            throw SupabaseError.serverError(http.statusCode, msg)
        }
        if let auth = try? JSONDecoder().decode(AuthResponse.self, from: data) {
            let s = makeSession(from: auth)
            save(s); session = s
            PostHogService.shared.capture("auth_sign_up", properties: ["method": "email"])
            return s
        }
        // 200 with no access_token = signup accepted, email confirmation pending.
        PostHogService.shared.capture("auth_sign_up", properties: ["method": "email", "status": "pending_confirmation"])
        return nil
    }

    // MARK: - Apple ID token sign-in

    func signInWithApple(idToken: String, nonce: String? = nil) async throws -> SupabaseSession {
        var body: [String: Any] = ["provider": "apple", "id_token": idToken]
        if let nonce { body["nonce"] = nonce }
        let auth = try await post(
            path: "/auth/v1/token?grant_type=id_token",
            body: body,
            as: AuthResponse.self
        )
        let s = makeSession(from: auth)
        save(s)
        session = s
        PostHogService.shared.capture("auth_sign_in", properties: ["method": "apple"])
        return s
    }

    // MARK: - Apple WEB OAuth (browser flow — no entitlement, works for Developer ID)
    //
    // Native Sign in with Apple needs the com.apple.developer.applesignin
    // entitlement, which a Developer-ID (direct-distribution) Mac app can't carry
    // (AMFI denies launch). The browser OAuth flow sidesteps that entirely: open
    // Supabase's /authorize URL in the browser, the user signs in with Apple,
    // Supabase redirects back to our custom URL scheme (mira://auth-callback) with
    // the session tokens in the URL fragment, and we adopt them.

    static let oauthRedirect = "mira://auth-callback"

    /// The URL to open in the browser to start Apple web sign-in.
    func appleOAuthURL() -> URL? {
        var c = URLComponents(string: baseURL + "/auth/v1/authorize")
        c?.queryItems = [
            URLQueryItem(name: "provider", value: "apple"),
            URLQueryItem(name: "redirect_to", value: Self.oauthRedirect),
        ]
        return c?.url
    }

    /// Adopt the session from the OAuth callback URL
    /// (mira://auth-callback#access_token=…&refresh_token=…&expires_in=…).
    /// Throws if the callback carried an error or no tokens.
    @discardableResult
    func completeAppleWebOAuth(callbackURL url: URL) throws -> SupabaseSession {
        // Tokens are in the fragment; an error comes back as query/fragment params.
        let raw = url.fragment ?? url.query ?? ""
        var params: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        if let err = params["error_description"] ?? params["error"] {
            throw SupabaseError.serverError(400, err.replacingOccurrences(of: "+", with: " "))
        }
        guard let access = params["access_token"], let refresh = params["refresh_token"] else {
            throw SupabaseError.serverError(400, "No tokens in the sign-in response.")
        }
        let expiresIn = Int(params["expires_in"] ?? "3600") ?? 3600
        let claims = Self.decodeJWTClaims(access)
        let s = SupabaseSession(
            accessToken: access, refreshToken: refresh,
            userId: claims.userId, email: claims.email,
            displayName: claims.email?.components(separatedBy: "@").first,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)))
        save(s)
        session = s
        PostHogService.shared.capture("auth_sign_in", properties: ["method": "apple_web"])
        return s
    }

    /// Decodes the `sub` (user id) and `email` claims from a JWT's payload without
    /// verifying the signature (the token came straight from our own auth server).
    static func decodeJWTClaims(_ jwt: String) -> (userId: String, email: String?) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return ("", nil) }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", nil) }
        return (json["sub"] as? String ?? "", json["email"] as? String)
    }

    // MARK: - Refresh

    func refresh() async throws {
        guard let current = session else { throw SupabaseError.noSession }
        let body = ["refresh_token": current.refreshToken]
        let auth = try await post(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: body,
            as: AuthResponse.self
        )
        let s = makeSession(from: auth)
        save(s)
        session = s
    }

    // MARK: - Auto-refresh
    //
    // The access token expires ~1h after sign-in, and nothing renewed it before —
    // so every proxy-gated feature (chat, voice, element grounding) silently 401'd
    // an hour after sign-in. These keep `cachedAccessToken` fresh transparently for
    // all call sites: a repeating timer polls `ensureFreshToken()` (a cheap no-op
    // until the token is within `buffer` of expiry), `observeSystemWake()` refreshes
    // on wake-from-sleep, and AppDelegate calls `ensureFreshToken()` at launch and on
    // app reactivation. The poll is repeating rather than a single long-delay one-shot
    // because a run-loop Timer is suspended during sleep — a 58-min one-shot fires far
    // too late; a frequent repeating timer fires once promptly on wake and resumes.

    private var refreshTimer: Timer?
    private var refreshInFlight: Task<Void, Error>?

    /// Refreshes the token if it's expired or within `buffer` of expiring. No-op
    /// when signed out or comfortably valid. Concurrent callers share one network
    /// refresh — rotating the (single-use) refresh token twice would invalidate one.
    func ensureFreshToken(buffer: TimeInterval = 120) async {
        guard let s = session, s.expiresAt.timeIntervalSinceNow <= buffer else { return }
        do { try await singleFlightRefresh() }
        catch {
            // A dead/rotated/expired refresh token can't recover — surface as
            // signed-out instead of 401'ing every call forever.
            if case SupabaseError.serverError(let code, _) = error, code == 400 || code == 401 {
                signOut()
            }
        }
    }

    /// Forces a token refresh in response to a server 401 — the token was rejected
    /// even if our clock still considers it valid (skew, server-side revocation, a
    /// refresh that lost a race). Single-flights with the proactive refresh so two
    /// callers can't rotate the single-use refresh token twice. Returns true if a
    /// usable session remains, so the caller knows whether retrying is worthwhile. A
    /// dead refresh token signs out, so callers stop retrying into a 401 loop.
    func refreshAfter401() async -> Bool {
        guard session != nil else { return false }
        do { try await singleFlightRefresh(); return session != nil }
        catch {
            if case SupabaseError.serverError(let code, _) = error, code == 400 || code == 401 {
                signOut()
            }
            return false
        }
    }

    private func singleFlightRefresh() async throws {
        if let inFlight = refreshInFlight { return try await inFlight.value }
        let task = Task { try await self.refresh() }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    /// (Re)starts the auto-refresh poll. Invoked from the session didSet, so every
    /// sign-in / refresh / launch-restore (re)arms it; a nil session tears it down.
    private func scheduleAutoRefresh() {
        refreshTimer?.invalidate()
        guard session != nil else { refreshTimer = nil; return }
        let t = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.ensureFreshToken() }
        }
        t.tolerance = 30   // let the OS coalesce — this is a cheap liveness check
        refreshTimer = t
    }

    // MARK: - Sign Out

    func signOut() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
        session = nil
        PostHogService.shared.capture("auth_sign_out")
    }

    // MARK: - Authenticated request helper

    func authedRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let session else { throw SupabaseError.noSession }
        guard let url = URL(string: baseURL + path) else { throw SupabaseError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SupabaseError.serverError(http.statusCode, msg)
        }
        return data
    }

    // MARK: - Internals

    private func post<B: Encodable, R: Decodable>(path: String, body: B, as: R.Type) async throws -> R {
        guard let url = URL(string: baseURL + path) else { throw SupabaseError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req, as: R.self)
    }

    private func post<R: Decodable>(path: String, body: [String: Any], as: R.Type) async throws -> R {
        guard let url = URL(string: baseURL + path) else { throw SupabaseError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req, as: R.self)
    }

    private func send<R: Decodable>(_ req: URLRequest, as: R.Type) async throws -> R {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw SupabaseError.network(error) }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Server error"
            throw SupabaseError.serverError(http.statusCode, msg)
        }
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw SupabaseError.decodingError(error) }
    }

    private func makeSession(from auth: AuthResponse) -> SupabaseSession {
        SupabaseSession(
            accessToken:  auth.accessToken,
            refreshToken: auth.refreshToken,
            userId:       auth.user.id,
            email:        auth.user.email,
            displayName:  auth.user.displayName,
            expiresAt:    Date().addingTimeInterval(TimeInterval(auth.expiresIn))
        )
    }

    private func save(_ s: SupabaseSession) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func loadSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let s = try? JSONDecoder().decode(SupabaseSession.self, from: data) else { return }
        session = s
    }
}
