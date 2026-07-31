// AICodingHookInstaller.swift
// Writes the CLI-side half of the AI Coding bridge: a hook script, plus the
// entries in ~/.claude/settings.json that make Claude Code run it.
//
// The script lives in Application Support rather than inside the .app bundle.
// A hook path is recorded in the user's settings and has to keep working after
// the app is moved, updated, or replaced by Sparkle — a path into
// /Applications/Mira.app/Contents/Resources survives none of those reliably.
//
// Nothing here runs on its own. Installing edits the user's own tooling config,
// so it happens only when they press the button in the module.

import Foundation

@MainActor
final class AICodingHookInstaller: ObservableObject {

    static let shared = AICodingHookInstaller()

    @Published private(set) var isInstalled = false
    @Published private(set) var lastError: String?

    private let fm = FileManager.default

    private init() { refresh() }

    // MARK: - Paths

    var hookDirectory: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mira/hooks", isDirectory: true)
    }

    var scriptURL: URL {
        hookDirectory.appendingPathComponent("mira-aicoding-hook.sh")
    }

    var claudeSettingsURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Hook events we register. PreToolUse is the one that can gate; the rest
    /// exist so a session's lifecycle shows up without polling anything.
    private var registeredEvents: [String] { ["PreToolUse", "PostToolUse", "SessionStart", "Stop", "SessionEnd"] }

    // MARK: - State

    func refresh() {
        isInstalled = fm.isExecutableFile(atPath: scriptURL.path) && settingsReferenceScript()
    }

    private func settingsReferenceScript() -> Bool {
        guard let root = readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for event in registeredEvents {
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            let found = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(scriptURL.path) == true
                } == true
            }
            if !found { return false }
        }
        return true
    }

    // MARK: - Install

    func install() {
        do {
            try writeScript()
            try updateSettings { hooks in
                for event in self.registeredEvents {
                    var groups = (hooks[event] as? [[String: Any]]) ?? []
                    groups.removeAll { self.isMiraGroup($0) }
                    groups.append(self.hookGroup(for: event))
                    hooks[event] = groups
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        do {
            try updateSettings { hooks in
                for event in self.registeredEvents {
                    guard var groups = hooks[event] as? [[String: Any]] else { continue }
                    groups.removeAll { self.isMiraGroup($0) }
                    if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
                }
            }
            try? fm.removeItem(at: scriptURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Ours is any group whose command mentions our script path. Matching on the
    /// path rather than on position is what makes install idempotent and lets
    /// uninstall leave the user's other hooks — including any they wrote for
    /// the same event — completely alone.
    private func isMiraGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(scriptURL.path) == true
        } == true
    }

    private func hookGroup(for event: String) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\(shellQuoted(scriptURL.path)) claude-code"
            ]]
        ]
        // Only tool events take a matcher; a SessionStart group with one is
        // meaningless and Claude Code would be right to ignore it.
        if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
        return group
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Settings I/O

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Read-modify-write of the user's settings, preserving every key we don't
    /// own. Writes through a temporary file and replaces atomically: a partial
    /// write here would break the user's CLI, not just this feature.
    private func updateSettings(_ mutate: (inout [String: Any]) -> Void) throws {
        var root = readSettings() ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        mutate(&hooks)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        try fm.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    private func writeScript() throws {
        try fm.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        try Self.script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - The script

    /// Pure POSIX sh with `nc` — no jq, no node, no python. This runs on every
    /// tool call in the user's CLI, so its only jobs are to be fast and to get
    /// out of the way completely when Mira isn't listening.
    static let script = #"""
    #!/bin/sh
    # Mira — AI Coding bridge hook.
    #
    # Installed by Mira (Settings ▸ AI Coding, or the module's Connect button).
    # Reads a Claude Code hook payload on stdin, forwards it to Mira's Unix
    # socket, and for gated tools waits briefly for an Allow/Deny.
    #
    # Every failure path exits 0 with no output, which tells Claude Code to carry
    # on with its normal permission prompt. Mira not running, not installed, or
    # wedged must never block your CLI.
    #
    # Usage: mira-aicoding-hook.sh <source>      e.g. claude-code

    SOURCE=${1:-claude-code}
    SOCK="/tmp/mira-aicoding-$(id -u).sock"

    [ -S "$SOCK" ] || exit 0

    NC=$(command -v nc 2>/dev/null) || exit 0
    [ -n "$NC" ] || exit 0

    # Collapse to one line. JSON escapes real newlines inside strings, so raw
    # CR/LF here are only pretty-printing and are safe to drop.
    payload=$(tr -d '\r\n')
    [ -n "$payload" ] || exit 0

    # Must be an object; we splice our own key in after the opening brace rather
    # than shelling out to a JSON tool that may not be installed.
    case "$payload" in
      \{*) ;;
      *) exit 0 ;;
    esac
    line="{\"source\":\"$SOURCE\",${payload#\{}"

    # -w is an idle timeout. It has to outlast Mira's decision window, or nc
    # hangs up first and the user's click lands on a closed socket.
    reply=$(printf '%s\n' "$line" | "$NC" -U -w 25 "$SOCK" 2>/dev/null | head -n 1)

    case "$reply" in
      *'"approved":true'*)
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved in Mira"}}'
        ;;
      *'"approved":false'*)
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied in Mira"}}'
        ;;
    esac

    exit 0
    """#
}
