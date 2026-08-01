// CodeHostingModule.swift
// MacNotch's Code hosting module: pull requests waiting on your review, plus
// the ones you opened. Scored ❌ in the audit (zero GitLab/Bitbucket hits).
//
// GitHub only for now, behind a `CodeHost` protocol. MacNotch supports GitHub,
// GitLab and Bitbucket; building all three before knowing whether the panel
// earns a dock slot would be three API surfaces to maintain on a guess. The
// seam is here so adding one is a file, not a refactor.
//
// The token lives in the KEYCHAIN, following the pattern SpotifyAuthService
// already established. A PAT grants repo access — putting it in UserDefaults
// would leave it in a plist readable by anything running as the user.
//
// Uses GitHub's SEARCH api rather than listing repos: "PRs awaiting my review"
// is a query, and reconstructing it by enumerating repositories would be many
// requests and would still miss repos outside the user's orgs.

import SwiftUI
import Combine
import Security
import AppKit

// MARK: - Model

struct PullRequest: Identifiable, Equatable {
    let id: Int
    let number: Int
    let title: String
    let repo: String
    let author: String
    let url: URL
    let updatedAt: Date
    let isDraft: Bool
    /// True when it's waiting on the signed-in user, false when they opened it.
    let awaitingReview: Bool
}

// MARK: - Host protocol

protocol CodeHost {
    var name: String { get }
    func fetch(token: String) async throws -> [PullRequest]
}

// MARK: - GitHub

struct GitHubHost: CodeHost {

    let name = "GitHub"

    func fetch(token: String) async throws -> [PullRequest] {
        async let review = search("is:open is:pr review-requested:@me", token: token, awaiting: true)
        async let mine   = search("is:open is:pr author:@me", token: token, awaiting: false)
        // Review requests first — that's the queue with someone else blocked on you.
        return try await review + mine
    }

    private func search(_ query: String, token: String, awaiting: Bool) async throws -> [PullRequest] {
        var comps = URLComponents(string: "https://api.github.com/search/issues")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "sort", value: "updated"),
            .init(name: "per_page", value: "20")
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodeHostError.badResponse }
        guard http.statusCode == 200 else {
            throw CodeHostError.http(http.statusCode)
        }

        struct Response: Decodable {
            struct Item: Decodable {
                let id: Int
                let number: Int
                let title: String
                let html_url: URL
                let updated_at: String
                let draft: Bool?
                let user: User
                struct User: Decodable { let login: String }
            }
            let items: [Item]
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let iso = ISO8601DateFormatter()

        return decoded.items.map { item in
            // The search API returns no repo field, but the html_url path is
            // /owner/repo/pull/N — deriving from it avoids a request per PR.
            let parts = item.html_url.pathComponents
            let repo = parts.count >= 3 ? "\(parts[1])/\(parts[2])" : "—"
            return PullRequest(
                id: item.id,
                number: item.number,
                title: item.title,
                repo: repo,
                author: item.user.login,
                url: item.html_url,
                updatedAt: iso.date(from: item.updated_at) ?? .distantPast,
                isDraft: item.draft ?? false,
                awaitingReview: awaiting
            )
        }
    }
}

enum CodeHostError: LocalizedError {
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response"
        case .http(401), .http(403):
            return "Token rejected — check it has `repo` scope and hasn't expired"
        case .http(let code): return "GitHub returned \(code)"
        }
    }
}

// MARK: - Service

@MainActor
final class CodeHostingService: ObservableObject {

    static let shared = CodeHostingService()

    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasToken = false

    private let host: CodeHost = GitHubHost()
    private var refreshTimer: Timer?

    /// Presence only. This runs at app launch, because the module is
    /// constructed in AppDelegate's registration list, and the previous version
    /// answered "do I have a token?" by decrypting the token — which makes
    /// macOS check the keychain ACL and, on a build whose signing identity it
    /// can't durably match, put up a password prompt on every single launch.
    /// Reading a secret to test for its existence was wrong regardless of the
    /// prompt; the prompt just made it obvious.
    private init() { hasToken = Self.tokenExists() }

    // MARK: Token (Keychain)

    nonisolated private static let kcService = "mira.codehosting"
    nonisolated private static let kcAccount = "github_pat"

    static func writeToken(_ token: String) {
        let base: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        kcService,
            kSecAttrAccount:        kcAccount,
            kSecAttrSynchronizable: kCFBooleanFalse!,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData]      = Data(token.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Does an item exist, without decrypting it.
    ///
    /// `kSecReturnAttributes` with no `kSecReturnData` asks only whether the
    /// row is there, so the keychain never has to unlock the secret and never
    /// consults the ACL that triggers the prompt.
    static func tokenExists() -> Bool {
        let query: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        kcService,
            kSecAttrAccount:        kcAccount,
            kSecAttrSynchronizable: kCFBooleanFalse!,
            kSecReturnAttributes:   true,
            kSecReturnData:         false,
        ]
        var item: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// `nonisolated` so it can be called off the main actor — see `refresh()`
    /// for why it must be. It touches no actor state; the Keychain query is
    /// built from constants.
    nonisolated static func readToken() -> String? {
        let q: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        kcService,
            kSecAttrAccount:        kcAccount,
            kSecAttrSynchronizable: kCFBooleanFalse!,
            kSecReturnData:         true,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    func setToken(_ token: String) {
        Self.writeToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
        hasToken = Self.tokenExists()
        pullRequests = []
        error = nil
        if hasToken { Task { await refresh() } }
    }

    // MARK: Fetch

    func refresh() async {
        // Read the token OFF the main thread. SecItemCopyMatching decrypts the
        // item, and a decrypt can block for as long as the Keychain wants —
        // indefinitely, if it is waiting behind an authorisation prompt. This
        // service is @MainActor, so calling it directly froze the entire app:
        // a sample taken while the UI was unresponsive showed the main thread
        // parked in readToken → SecItemCopyMatching → CSSM_DecryptDataFinal,
        // and the module carousel had stopped responding to anything.
        let token = await Task.detached(priority: .userInitiated) {
            Self.readToken()
        }.value

        guard let token else {
            hasToken = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            pullRequests = try await host.fetch(token: token)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// GitHub's search endpoint is rate limited to 30 requests/minute
    /// authenticated, and this issues two per refresh — 5 minutes is well clear
    /// while staying fresh enough for a review queue.
    func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var awaitingCount: Int { pullRequests.filter(\.awaitingReview).count }
}

// MARK: - Module

@MainActor
final class CodeHostingModule: NotchModule, ObservableObject {

    let id    = "code"
    let title = "Code"
    let icon  = "chevron.left.forwardslash.chevron.right"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = CodeHostingService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        guard service.hasToken else { return nil }
        let n = service.awaitingCount
        guard n > 0 else { return nil }
        return NotchHeaderSubtitle(text: "\(n) to review", isPill: true)
    }

    var headerAccessories: [NotchHeaderAccessory] {
        guard service.hasToken else { return [] }
        return [NotchHeaderAccessory(id: "refresh", systemImage: "arrow.clockwise",
                                     label: "Refresh pull requests") { [weak self] in
            Task { await self?.service.refresh() }
        }]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() {
        service.startAutoRefresh()
        Task { await service.refresh() }
    }

    func didDisappear() { service.stopAutoRefresh() }

    func makeContent() -> AnyView { AnyView(CodeHostingView(service: service)) }
}

// MARK: - View

private struct CodeHostingView: View {

    @ObservedObject var service: CodeHostingService
    @ObservedObject private var accentSvc = AccentColorService.shared
    @State private var tokenDraft = ""

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if !service.hasToken {
                tokenPrompt
            } else {
                list
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    // MARK: Token entry

    /// Degrades to a clear "add a token" state rather than an empty list that
    /// looks like a bug or like you genuinely have no review requests.
    private var tokenPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.30))
            Text("Connect GitHub")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("A personal access token with `repo` scope. Stored in your Keychain, never sent anywhere but GitHub.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.40))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            HStack(spacing: 6) {
                SecureField("ghp_…", text: $tokenDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.90))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                    .frame(width: 220)
                    .onSubmit { service.setToken(tokenDraft); tokenDraft = "" }

                Button {
                    service.setToken(tokenDraft)
                    tokenDraft = ""
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(tokenDraft.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if let error = service.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1, green: 0.5, blue: 0.5))
                        .padding(.vertical, 6)
                }
                section("Awaiting your review", service.pullRequests.filter(\.awaitingReview))
                section("Opened by you", service.pullRequests.filter { !$0.awaitingReview })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if service.pullRequests.isEmpty && service.error == nil && !service.isLoading {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.22))
                    Text("No open pull requests")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PullRequest]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 6)
            ForEach(items) { pr in
                row(pr)
            }
        }
    }

    private func row(_ pr: PullRequest) -> some View {
        Button {
            NSWorkspace.shared.open(pr.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pr.isDraft ? "circle.dotted" : "arrow.triangle.pull")
                    .font(.system(size: 11))
                    .foregroundColor(pr.isDraft ? .white.opacity(0.35) : accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                        .lineLimit(1)
                    Text("\(pr.repo) #\(pr.number) · \(pr.author)")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(pr.updatedAt.formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(pr.repo) #\(pr.number) in browser")
    }
}
