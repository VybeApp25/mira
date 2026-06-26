import Foundation
import AuthenticationServices
import Combine

enum MiraAuthError: LocalizedError {
    case deviceAlreadyRegistered
    var errorDescription: String? {
        "A free account already exists on this Mac. Sign in to that account, or upgrade to Pro to use Mira on multiple devices."
    }
}

// MARK: - User

struct MiraUser: Codable, Equatable {
    let id: String
    let email: String?
    let displayName: String?
    let avatarURL: String?
    let createdAt: Date
}

// MARK: - Auth State

enum AuthState: Equatable {
    case signedOut
    case signedIn(MiraUser)
    case loading
}

// MARK: - Service

@MainActor
final class AccountService: NSObject, ObservableObject {
    static let shared = AccountService()

    @Published private(set) var authState: AuthState = .signedOut

    private let userKey = "mira_current_user"

    override init() {
        super.init()
        // Prefer Supabase session if available
        if let s = SupabaseService.shared.session {
            let user = MiraUser(
                id: s.userId,
                email: s.email,
                displayName: s.displayName,
                avatarURL: nil,
                createdAt: Date()
            )
            authState = .signedIn(user)
            Task { await EntitlementService.shared.fetchAndApplyPlan() }
        } else {
            loadSavedUser()
        }
    }

    var currentUser: MiraUser? {
        if case .signedIn(let user) = authState { return user }
        return nil
    }

    var isSignedIn: Bool { currentUser != nil }

    // MARK: - Apple Sign In

    func handleAppleAuthorization(_ authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        Task { @MainActor in
            guard let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                authState = .signedOut
                return
            }
            authState = .loading
            do {
                let s = try await SupabaseService.shared.signInWithApple(idToken: idToken)
                let user = MiraUser(
                    id: s.userId,
                    email: s.email ?? cred.email,
                    displayName: s.displayName ?? (name.isEmpty ? cred.email?.components(separatedBy: "@").first : name),
                    avatarURL: nil,
                    createdAt: Date()
                )
                saveUser(user)
                authState = .signedIn(user)
                PostHogService.shared.identify(userId: s.userId, email: s.email, name: s.displayName)
                await EntitlementService.shared.fetchAndApplyPlan()
                await registerDevice(DeviceFingerprintService.deviceHash, jwt: s.accessToken)
            } catch {
                authState = .signedOut
            }
        }
    }

    // MARK: - Email/Password via Supabase

    func signIn(email: String, password: String) async throws {
        authState = .loading
        do {
            let s = try await SupabaseService.shared.signIn(email: email, password: password)
            let user = MiraUser(
                id: s.userId,
                email: s.email,
                displayName: s.displayName ?? s.email?.components(separatedBy: "@").first,
                avatarURL: nil,
                createdAt: Date()
            )
            saveUser(user)
            authState = .signedIn(user)
            PostHogService.shared.identify(userId: s.userId, email: s.email, name: s.displayName)
            await EntitlementService.shared.fetchAndApplyPlan()
            Task { await registerDevice(DeviceFingerprintService.deviceHash, jwt: s.accessToken) }
        } catch {
            authState = .signedOut
            throw error
        }
    }

    func signUp(email: String, password: String, name: String) async throws {
        authState = .loading
        do {
            // Block signup if a free account already exists on this device
            let deviceHash = DeviceFingerprintService.deviceHash
            let available = await checkDeviceAvailable(deviceHash)
            guard available else {
                authState = .signedOut
                throw MiraAuthError.deviceAlreadyRegistered
            }

            guard let s = try await SupabaseService.shared.signUp(email: email, password: password, name: name) else {
                // Email confirmation required — not an error, just stay signed out.
                authState = .signedOut
                return
            }
            let user = MiraUser(
                id: s.userId,
                email: s.email,
                displayName: s.displayName ?? name,
                avatarURL: nil,
                createdAt: Date()
            )
            saveUser(user)
            authState = .signedIn(user)
            PostHogService.shared.identify(userId: s.userId, email: s.email, name: s.displayName)
            await EntitlementService.shared.fetchAndApplyPlan()
            Task { await registerDevice(deviceHash, jwt: s.accessToken) }
        } catch {
            authState = .signedOut
            throw error
        }
    }

    // MARK: - Device lock

    private func checkDeviceAvailable(_ hash: String) async -> Bool {
        guard let url = URL(string: AppSecrets.supabaseURL + "/functions/v1/check-device") else { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_hash": hash])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let available = json["available"] as? Bool else { return true }
        return available
    }

    // Fire-and-forget after sign-in. If the server returns 409 (another free account
    // owns this device), we sign the user out so they can't use Mira on this Mac.
    private func registerDevice(_ hash: String, jwt: String) async {
        guard let url = URL(string: AppSecrets.supabaseURL + "/functions/v1/register-device") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_hash": hash])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 409 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            if msg == "device_already_registered" {
                await MainActor.run { signOut() }
            }
        }
    }

    func signOut() {
        SupabaseService.shared.signOut()
        authState = .signedOut
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    // MARK: - Persistence

    private func saveUser(_ user: MiraUser) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: userKey)
        }
    }

    private func loadSavedUser() {
        guard let data = UserDefaults.standard.data(forKey: userKey),
              let user = try? JSONDecoder().decode(MiraUser.self, from: data) else { return }
        authState = .signedIn(user)
    }
}

