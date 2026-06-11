// IntegrationContextService.swift
// Phase 17+ — Loads per-integration instruction context from bundled MD files
// and injects the relevant subset into MiraPrompts.system.
//
// Built-in integrations (Spotify, iMessage, Apple Notes, Reminders) are always
// included — they use Realtime tools / AppleScript available without Composio.
// Composio integrations are included only when the connection is marked live.

import Foundation

@MainActor
final class IntegrationContextService {

    static let shared = IntegrationContextService()

    // Nonisolated cache — read by MiraPrompts.system from any context.
    nonisolated(unsafe) static var cachedContext: String = ""

    // Slugs whose MD files are always injected regardless of Composio status.
    private static let builtIn: Set<String> = [
        "spotify", "imessage", "apple-notes", "apple-reminders", "findmy",
        "maps", "computer-use", "claude-code",
    ]

    private init() {
        // Load built-ins immediately so the first system prompt is already enriched.
        let builtInContext = Self.buildContext(connected: [])
        Self.cachedContext = builtInContext
    }

    // Called by IntegrationsView after refresh() or a successful connect().
    // `connected` is the set of Composio toolkit slugs that are live.
    func update(connected: Set<String>) {
        Self.cachedContext = Self.buildContext(connected: connected)
        // Persist connected slugs so context survives restarts.
        UserDefaults.standard.set(Array(connected), forKey: "mira_connected_integrations")
    }

    // Called on launch to restore persisted connection state.
    func restoreFromDefaults() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: "mira_connected_integrations") ?? [])
        Self.cachedContext = Self.buildContext(connected: saved)
    }

    // MARK: - Context building

    private static func buildContext(connected: Set<String>) -> String {
        let active = builtIn.union(connected)
        let docs = active.sorted().compactMap { loadDoc(slug: $0) }
        guard !docs.isEmpty else { return "" }
        return "\n\n## Connected integrations\n\n" + docs.joined(separator: "\n\n---\n\n")
    }

    private static func loadDoc(slug: String) -> String? {
        guard let url = Bundle.main.url(
            forResource: slug,
            withExtension: "md",
            subdirectory: "Integrations"
        ),
        let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
