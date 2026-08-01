// ClaudeBridgeConfig.swift
// Registers Mira's MCP server (MiraMCPServer) with CLAUDE CODE, the way
// CodexBridgeConfig already does for Codex.
//
// Mira has served MCP for a while — an in-process, loopback-only
// streamable-HTTP server exposing MiraToolService — but only Codex was ever
// told about it. Claude Code speaks the same transport (`claude mcp add
// --transport http … --header "Authorization: Bearer …"`), so making Mira
// callable from Claude Code is registration, not new protocol work.
//
// After this, a Claude Code session can call Mira's tools directly: calendar,
// knowledge/memory, project context, screen and system actions.
//
// WHY EDIT THE FILE RATHER THAN SHELL OUT TO `claude mcp add`. The CLI is not
// guaranteed to be on PATH for a GUI-launched app, and it would mean spawning a
// process on every launch to write two lines of JSON. The file is the same
// destination either way.
//
// TWO REAL RISKS, both handled:
//
//   1. ~/.claude.json IS THE USER'S WHOLE CLAUDE CODE CONFIG — startup counts,
//      per-project history, everything. A careless write destroys state that is
//      not recoverable from anywhere. So this parses, mutates exactly one key,
//      and writes atomically, keeping a .mira-backup of the previous contents.
//      If the file is unparseable it does NOTHING rather than replace it.
//   2. THE BEARER TOKEN IS PER-LAUNCH. A Claude Code session started before
//      Mira relaunched holds a stale token and gets 401s. That is self-healing
//      on the next session, and the alternative — a token that never rotates,
//      written to disk forever — is worse. Mira rewrites this on every launch
//      and whenever the bound port moves.

import Foundation

enum ClaudeBridgeConfig {

    private static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// Point Claude Code at Mira's MCP server. Safe to call repeatedly.
    @discardableResult
    static func reconcile(port: UInt16, token: String) -> Bool {
        guard port != 0, !token.isEmpty else { return false }
        let url = configURL

        // No config means Claude Code has never run. Writing one for it would be
        // presumptuous and might not match the schema its version expects.
        guard let data = try? Data(contentsOf: url) else { return false }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Unparseable — leave it completely alone. Overwriting here would
            // trade a config Mira can't read for one the user has lost.
            return false
        }

        let desired: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"]
        ]

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers["mira"] as? [String: Any],
           existing["url"] as? String == desired["url"] as? String,
           (existing["headers"] as? [String: String])?["Authorization"] == "Bearer \(token)" {
            return true   // already correct, don't churn the file
        }
        servers["mira"] = desired
        root["mcpServers"] = servers

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }

        // Backup before the first write of a session, then replace atomically.
        let backup = url.appendingPathExtension("mira-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup)
        }
        do {
            try out.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Remove Mira's entry — for a user who wants Claude Code to stop seeing it.
    @discardableResult
    static func remove() -> Bool {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any],
              servers["mira"] != nil
        else { return false }

        servers.removeValue(forKey: "mira")
        root["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// Whether Claude Code currently points at Mira.
    static var isRegistered: Bool {
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return false }
        return servers["mira"] != nil
    }
}
