import Foundation
import AuthenticationServices
import Combine

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
        loadSavedUser()
    }

    var currentUser: MiraUser? {
        if case .signedIn(let user) = authState { return user }
        return nil
    }

    var isSignedIn: Bool { currentUser != nil }

    // MARK: - Apple Sign In (macOS-native, no backend required)

    func signInWithApple() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.performRequests()
    }

    // MARK: - Email/Password placeholder (wire to Supabase when backend is ready)

    func signIn(email: String, password: String) async throws {
        authState = .loading
        // TODO: wire to Supabase Auth or your backend
        // For now, create a local user so the entitlement system works
        let user = MiraUser(
            id: UUID().uuidString,
            email: email,
            displayName: email.components(separatedBy: "@").first,
            avatarURL: nil,
            createdAt: Date()
        )
        saveUser(user)
        authState = .signedIn(user)
    }

    func signUp(email: String, password: String, name: String) async throws {
        authState = .loading
        let user = MiraUser(
            id: UUID().uuidString,
            email: email,
            displayName: name,
            avatarURL: nil,
            createdAt: Date()
        )
        saveUser(user)
        authState = .signedIn(user)
    }

    func signOut() {
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

// MARK: - Apple auth delegate

extension AccountService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        let user = MiraUser(
            id: cred.user,
            email: cred.email,
            displayName: name.isEmpty ? cred.email?.components(separatedBy: "@").first : name,
            avatarURL: nil,
            createdAt: Date()
        )
        Task { @MainActor in
            self.saveUser(user)
            self.authState = .signedIn(user)
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            if self.authState == .loading { self.authState = .signedOut }
        }
    }
}
