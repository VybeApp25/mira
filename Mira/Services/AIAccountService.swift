// AIAccountService.swift
// Whether the user's OWN Claude and ChatGPT accounts are connected, for the CLI
// side of Mira.
//
// THE SPLIT THIS IMPLEMENTS. Mira's chat, voice, vision and routing keep going
// through the backend proxy on Mira's own keys — unchanged. Only the CLI lanes
// (RemoteControlService driving `claude`, CodexService driving `codex`) run on
// the user's own subscription. That is not a policy Mira has to enforce so much
// as a fact about how those CLIs work: they authenticate themselves, against
// whatever account the user logged in with, and Mira spawns them.
//
// SO MIRA NEVER HANDLES THEIR CREDENTIALS, and this file is careful to keep it
// that way. It answers one question per provider — "is there a session?" — and
// deliberately cannot answer "what is the token".
//
//   • Claude Code keeps its session in the login Keychain, service
//     "Claude Code-credentials". Existence is checked with kSecReturnAttributes
//     and NEVER kSecReturnData: asking for the data decrypts the item, which
//     prompts the user for their password and previously froze Mira's main
//     thread inside CSSM_DecryptDataFinal. Attributes alone need no decryption.
//   • Codex keeps ~/.codex/auth.json. Only `auth_mode`, `last_refresh` and the
//     PRESENCE of tokens.account_id are read. The tokens themselves are never
//     loaded into a property, logged, or sent anywhere.
//
// Connecting is done by the vendor's own login flow in a terminal, not by Mira.
// There is no public OAuth that would let a third-party app mint a session for a
// consumer Claude or ChatGPT account, and a "sign in" sheet inside Mira that
// collected those credentials would be phishing-shaped even with good
// intentions.

import Foundation
import AppKit
import Security

@MainActor
final class AIAccountService: ObservableObject {

    static let shared = AIAccountService()

    enum State: Equatable {
        /// The CLI isn't on this Mac.
        case notInstalled
        /// Installed, but nobody has logged in.
        case signedOut
        /// Signed in. `detail` names the mode when the CLI distinguishes one
        /// (Codex: a ChatGPT account vs a pasted API key).
        case connected(detail: String?)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published private(set) var claude: State = .notInstalled
    @Published private(set) var codex: State = .notInstalled

    private init() {}

    func refresh() {
        // Keychain and disk reads, off the main thread. Attributes-only lookups
        // are fast, but "fast" is what the last main-thread Keychain call was
        // assumed to be too.
        let claudeInstalled = RemoteControlService.executable != nil
        Task.detached(priority: .utility) {
            let claudeState = Self.claudeState(installed: claudeInstalled)
            let codexState  = Self.codexState()
            await MainActor.run {
                if self.claude != claudeState { self.claude = claudeState }
                if self.codex  != codexState  { self.codex  = codexState  }
            }
        }
    }

    // MARK: - Claude

    private nonisolated static func claudeState(installed: Bool) -> State {
        // Resolution lives on RemoteControlService and is main-actor isolated,
        // so the caller passes the answer in rather than hopping back mid-probe.
        guard installed else { return .notInstalled }
        return hasKeychainSession(service: "Claude Code-credentials")
            ? .connected(detail: nil)
            : .signedOut
    }

    /// Existence only. `kSecReturnAttributes` returns metadata without
    /// decrypting the secret, so this neither prompts nor blocks; asking for
    /// `kSecReturnData` would do both.
    private nonisolated static func hasKeychainSession(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String:       false,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    // MARK: - Codex

    private nonisolated static func codexState() -> State {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.local/bin/codex"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return .notInstalled }

        let authURL = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .signedOut }

        // Read the SHAPE, never the secrets.
        let mode = json["auth_mode"] as? String
        let tokens = json["tokens"] as? [String: Any]
        let hasChatGPTSession = (tokens?["account_id"] as? String)?.isEmpty == false
        let hasAPIKey = (json["OPENAI_API_KEY"] as? String)?.isEmpty == false

        if hasChatGPTSession { return .connected(detail: "ChatGPT account") }
        if mode == "apikey" || hasAPIKey { return .connected(detail: "API key") }
        return .signedOut
    }

    // MARK: - Connecting

    enum Provider { case claude, codex }

    /// Hands the user to the vendor's own login flow in Terminal.
    ///
    /// Mira runs the command for them and stops there — the browser handoff,
    /// the account choice and the consent all belong to Anthropic and OpenAI.
    /// This deliberately does not try to drive or scrape that flow.
    func connect(_ provider: Provider) {
        let command: String
        switch provider {
        case .claude:
            command = (RemoteControlService.executable.map { "\"\($0)\" /login" })
                ?? "claude /login"
        case .codex:
            command = "codex login"
        }

        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        if let apple = NSAppleScript(source: script) {
            var error: NSDictionary?
            apple.executeAndReturnError(&error)
        }
        // The flow finishes in the browser, well after this returns, so re-check
        // on a delay rather than immediately reporting the old state.
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { self?.refresh() }
                let connected = await MainActor.run { self?.state(for: provider).isConnected == true }
                if connected { break }
            }
        }
    }

    func state(for provider: Provider) -> State {
        switch provider {
        case .claude: return claude
        case .codex:  return codex
        }
    }

    /// What the CLI is called, for install guidance.
    static func installHint(for provider: Provider) -> String {
        switch provider {
        case .claude: return "Install Claude Code, then connect your Claude account"
        case .codex:  return "npm install -g @openai/codex"
        }
    }
}
