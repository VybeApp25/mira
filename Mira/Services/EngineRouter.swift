// EngineRouter.swift
// Mira's invisible desktop-control engine selector. The user never picks (or
// sees) whether a task runs on the Codex computer-use engine or the Claude
// vision engine — they just see Mira get it done. This makes the call from
// deterministic, zero-cost signals (no extra LLM round-trip), and pairs with a
// transparent failover in RouterService so a refusal/failure on the first
// engine silently retries on the other.
//
// Selection is intentionally conservative — it only acts on signals we can
// actually justify, not invented "speed" guesses:
//   • Availability — if the Codex CLI isn't installed/authed, only Claude is viable.
//   • App safety   — Codex enforces its OWN app allow/deny list (it refuses
//                    Terminal, Keychain, etc.). For those, skip Codex entirely so
//                    we don't burn a run on a guaranteed refusal — Claude's AX /
//                    vision path has no such block.
//   • Default      — the Claude (Sonnet 5) vision loop leads: it verifies every
//                    action against a fresh screenshot, so it doesn't claim
//                    clicks it didn't land. Codex is the failover.

import Foundation

@MainActor
final class EngineRouter {
    static let shared = EngineRouter()
    private init() {}

    enum Engine: String { case codex, claude }

    struct Plan {
        let primary: Engine
        let secondary: Engine?   // transparent failover; nil = no retry
        let reason: String       // internal logging only — never shown to the user

        /// A user-forced single engine (Settings override) — no failover.
        static func forced(_ e: Engine) -> Plan { Plan(primary: e, secondary: nil, reason: "user override") }
    }

    /// Apps Codex's computer-use plugin is known to refuse for safety. Asking it
    /// to drive these just wastes a run, so route them straight to Claude.
    private let codexBlockedApps = [
        "terminal", "iterm", "console", "keychain", "activity monitor",
        "1password", "bitwarden", "lastpass",
    ]

    /// Pick the engine(s) for a desktop-control task. Async because the Codex
    /// availability probe shells out (cached after the first call).
    func planDesktopControl(_ task: String) async -> Plan {
        let lower = task.lowercased()

        // Hard signal: a target app Codex won't control → Claude only.
        if codexBlockedApps.contains(where: { lower.contains($0) }) {
            return Plan(primary: .claude, secondary: nil,
                        reason: "target app is outside Codex's allowed set")
        }

        // Hard signal: Codex unavailable → Claude only.
        if await !CodexService.shared.isInstalled() {
            return Plan(primary: .claude, secondary: nil, reason: "Codex CLI unavailable")
        }

        // Default: the Claude (Sonnet 5) vision loop leads — it verifies every
        // action against a post-action screenshot — with Codex as the failover.
        return Plan(primary: .claude, secondary: .codex, reason: "general GUI control")
    }
}
