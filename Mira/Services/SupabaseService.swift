import Foundation

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
        didSet { Self.cachedAccessToken = session?.accessToken ?? "" }
    }

    // Thread-safe mirror of the current JWT so non-MainActor network call sites
    // (e.g. MiraBackend) can attach it without an actor hop. Updated on every
    // session change via the didSet above.
    nonisolated(unsafe) static var cachedAccessToken: String = ""

    private let baseURL = AppSecrets.supabaseURL
    private let anonKey = AppSecrets.supabaseAnonKey
    private let sessionKey = "mira_supabase_session"

    private init() { loadSession() }

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

    func signUp(email: String, password: String, name: String) async throws -> SupabaseSession {
        let body: [String: Any] = [
            "email": email,
            "password": password,
            "data": ["display_name": name]
        ]
        let auth = try await post(
            path: "/auth/v1/signup",
            body: body,
            as: AuthResponse.self
        )
        let s = makeSession(from: auth)
        save(s)
        session = s
        PostHogService.shared.capture("auth_sign_up", properties: ["method": "email"])
        return s
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
