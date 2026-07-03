import Foundation
import AppKit
import CryptoKit

/// Client-side Spotify **user** authorization (Authorization Code + PKCE).
///
/// Why this exists: Mira's `spotify-search` edge function uses the *Client
/// Credentials* flow, which only grants catalog/search access — it CANNOT touch a
/// user's library. Favoriting a track, adding it to a playlist, or following an
/// artist all require a per-user token with the right scopes. PKCE is the flow
/// Spotify recommends for native/desktop apps: it needs only the PUBLIC client ID
/// (fetched from the `spotify-config` edge function) and never the client secret,
/// so the whole exchange happens on-device.
///
/// Flow: `connect()` opens the system browser to Spotify's consent page →
/// Spotify redirects to `mira://spotify/callback?code=…` → AppDelegate forwards it
/// to `handleCallback(_:)` → we exchange the code for tokens and stash the refresh
/// token in the login Keychain. `validAccessToken()` transparently refreshes.
@MainActor
final class SpotifyAuthService: ObservableObject {
    static let shared = SpotifyAuthService()
    private init() { isConnected = Self.readRefreshToken() != nil }

    /// True once the user has completed the consent flow at least once (a refresh
    /// token is on file). Drives Settings UI + the "connect Spotify" chip fallback.
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false

    // Exact string that MUST also be registered as a Redirect URI in the Spotify
    // developer dashboard for the Mira app. Uses the app's existing `mira://` scheme.
    static let redirectURI = "mira://spotify/callback"

    private let scopes = [
        "user-library-read", "user-library-modify",
        "playlist-read-private", "playlist-modify-public", "playlist-modify-private",
        "user-follow-read", "user-follow-modify",
        "user-read-currently-playing", "user-read-playback-state",
    ].joined(separator: " ")

    // In-flight PKCE state (kept only between connect() and the callback).
    private var pendingVerifier: String?
    private var pendingState:    String?
    private var authContinuation: CheckedContinuation<Bool, Never>?

    // Cached access token (memory only — cheap to re-mint from the refresh token).
    private var accessToken:  String?
    private var accessExpiry: Date = .distantPast

    // Cached public client ID (fetched once from the backend, then remembered).
    private var cachedClientID: String?

    // MARK: - Public API

    /// Kicks off the browser consent flow. Returns true once tokens are stored.
    /// Safe to call when already connected (re-consents / refreshes scopes).
    @discardableResult
    func connect() async -> Bool {
        guard !isConnecting else { return isConnected }
        guard let clientID = await clientID(), !clientID.isEmpty else {
            NSLog("[SpotifyAuth] no client ID — is the user signed in and SPOTIFY_CLIENT_ID set?")
            return false
        }

        isConnecting = true
        defer { isConnecting = false }

        let verifier  = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state     = Self.randomURLSafe(16)
        pendingVerifier = verifier
        pendingState    = state

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id",             value: clientID),
            .init(name: "response_type",         value: "code"),
            .init(name: "redirect_uri",          value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "state",                 value: state),
            .init(name: "scope",                 value: scopes),
        ]
        guard let url = comps.url else { return false }
        NSWorkspace.shared.open(url)

        // Await the redirect (or a 3-minute timeout so we never leak the continuation).
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            authContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                await self?.failAuth(reason: "timed out")
            }
        }
        return ok
    }

    /// Called by AppDelegate when a `mira://spotify/callback` URL arrives.
    func handleCallback(_ url: URL) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            await failAuth(reason: "bad callback URL"); return
        }
        let items = comps.queryItems ?? []
        let code  = items.first(where: { $0.name == "code" })?.value
        let state = items.first(where: { $0.name == "state" })?.value
        if let err = items.first(where: { $0.name == "error" })?.value {
            await failAuth(reason: "user denied (\(err))"); return
        }
        guard let code, state == pendingState, let verifier = pendingVerifier else {
            await failAuth(reason: "state mismatch"); return
        }
        let ok = await exchangeCode(code, verifier: verifier)
        finishAuth(ok)
    }

    /// Disconnects — wipes the stored refresh token and cached access token.
    func disconnect() {
        Self.deleteRefreshToken()
        accessToken = nil
        accessExpiry = .distantPast
        isConnected = false
    }

    /// A currently-valid access token, refreshing from the stored refresh token if
    /// the cached one is missing or within 60s of expiry. Returns nil if the user
    /// has never connected or the refresh fails.
    func validAccessToken() async -> String? {
        if let token = accessToken, Date() < accessExpiry.addingTimeInterval(-60) {
            return token
        }
        guard let refresh = Self.readRefreshToken() else { return nil }
        guard let clientID = await clientID() else { return nil }
        return await refreshAccessToken(refresh: refresh, clientID: clientID)
    }

    // MARK: - Token exchange / refresh

    private struct TokenResponse: Decodable {
        let access_token:  String
        let expires_in:    Int
        let refresh_token: String?
    }

    private func exchangeCode(_ code: String, verifier: String) async -> Bool {
        guard let clientID = await clientID() else { return false }
        // client_id in the body (no secret) marks this as a public PKCE client.
        let params = [
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  Self.redirectURI,
            "client_id":     clientID,
            "code_verifier": verifier,
        ]
        guard let resp = await postToken(params) else { return false }
        applyTokens(resp)
        return true
    }

    private func refreshAccessToken(refresh: String, clientID: String) async -> String? {
        let params = [
            "grant_type":    "refresh_token",
            "refresh_token": refresh,
            "client_id":     clientID,
        ]
        guard let resp = await postToken(params) else {
            // A hard failure (revoked/expired refresh token) should surface as a
            // disconnect so the UI can re-prompt rather than silently failing.
            NSLog("[SpotifyAuth] refresh failed — clearing stored token")
            disconnect()
            return nil
        }
        applyTokens(resp)
        return resp.access_token
    }

    private func applyTokens(_ resp: TokenResponse) {
        accessToken  = resp.access_token
        accessExpiry = Date().addingTimeInterval(TimeInterval(resp.expires_in))
        // Spotify only returns a new refresh token sometimes; keep the old one if not.
        if let newRefresh = resp.refresh_token {
            Self.writeRefreshToken(newRefresh)
        }
        isConnected = true
    }

    private func postToken(_ params: [String: String]) async -> TokenResponse? {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                NSLog("[SpotifyAuth] token endpoint \(status): \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            NSLog("[SpotifyAuth] token network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Continuation plumbing

    private func finishAuth(_ ok: Bool) {
        pendingVerifier = nil
        pendingState    = nil
        authContinuation?.resume(returning: ok)
        authContinuation = nil
    }

    private func failAuth(reason: String) async {
        guard authContinuation != nil else { return }
        NSLog("[SpotifyAuth] auth failed: \(reason)")
        finishAuth(false)
    }

    // MARK: - Client ID (fetched from backend, then cached)

    private func clientID() async -> String? {
        if let id = cachedClientID { return id }
        // Optional local override (AppSecrets.spotifyClientID) wins if present.
        if !AppSecrets.spotifyClientID.isEmpty {
            cachedClientID = AppSecrets.spotifyClientID
            return cachedClientID
        }
        let jwt = SupabaseService.cachedAccessToken
        guard MiraBackend.useProxy, !jwt.isEmpty else { return nil }
        var req = URLRequest(url: MiraBackend.spotifyConfigURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["client_id"] as? String, !id.isEmpty else { return nil }
            cachedClientID = id
            return id
        } catch {
            NSLog("[SpotifyAuth] client-id fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Keychain (refresh token, login-Keychain only, never iCloud)

    private static let kcService = "mira.spotify"
    private static let kcAccount = "refresh_token"

    private static func writeRefreshToken(_ token: String) {
        let base: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        kcService,
            kSecAttrAccount:        kcAccount,
            kSecAttrSynchronizable: kCFBooleanFalse!,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData]      = Data(token.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readRefreshToken() -> String? {
        let q: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        kcService,
            kSecAttrAccount:        kcAccount,
            kSecAttrSynchronizable: kCFBooleanFalse!,
            kSecReturnData:         true,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteRefreshToken() {
        let q: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: kcService,
            kSecAttrAccount: kcAccount,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
