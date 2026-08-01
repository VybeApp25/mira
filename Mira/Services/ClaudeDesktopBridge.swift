// ClaudeDesktopBridge.swift
// Makes Mira a CONNECTOR in Claude Desktop, exposing the same 34 tools Claude
// Code now reaches over HTTP.
//
// WHY THIS IS NOT JUST ANOTHER CONFIG ENTRY. Claude Code accepts a loopback HTTP
// MCP server directly (`type: "http"`), which is why ClaudeBridgeConfig is
// twenty lines. Claude Desktop's local connectors are STDIO: it spawns a process
// and speaks newline-delimited JSON-RPC over its stdin/stdout. Mira is a GUI app
// and cannot be that process, so something has to sit between them.
//
// THE SHIM IS A SHELL SCRIPT, deliberately.
//
// The alternatives were worse. A second compiled target means an embedded helper
// binary, a copy phase, and its own signing — real build surface for a program
// that forwards bytes. Re-entering Mira's own binary with a flag means an
// argv check ahead of NSApplicationMain and a second instance of a GUI app
// running headless. `sh` and `curl` are both guaranteed present on macOS, the
// whole relay is a dozen lines, and the user can read it — which matters for
// something their AI client executes on every launch.
//
// TOKEN ROTATION IS WHY THE ENDPOINT LIVES IN A FILE. Mira's bearer token is
// per-launch and its port can move. Claude Desktop reads its config and spawns
// the shim ONCE, at ITS launch — so anything baked into the config or the
// process environment is stale the moment Mira restarts. The shim therefore
// re-reads the endpoint file on EVERY request. Restarting Mira does not break a
// running Claude Desktop session.
//
// The endpoint file holds the URL and token on two plain lines rather than JSON,
// so the shim can read it with `read` and no parser. It is written 0600; the
// token is a loopback credential for a server bound to 127.0.0.1 only.

import Foundation

enum ClaudeDesktopBridge {

    // MARK: - Paths

    private static var supportDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var endpointFile: URL { supportDirectory.appendingPathComponent("mcp-endpoint") }
    static var shimFile: URL { supportDirectory.appendingPathComponent("mira-mcp-stdio.sh") }

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    // MARK: - Shim

    /// Reads the endpoint fresh per request, so a Mira restart mid-session does
    /// not strand a running Claude Desktop.
    ///
    /// Only non-empty replies are printed: JSON-RPC NOTIFICATIONS (no `id`) get
    /// no response, and echoing a blank line for them corrupts the stream.
    private static func shimScript(endpoint: URL) -> String {
        """
        #!/bin/sh
        # Written by Mira. Relays MCP stdio <-> Mira's loopback HTTP MCP server.
        # The endpoint is re-read per request on purpose: Mira's port and bearer
        # token change when it restarts, and Claude Desktop spawns this script
        # only once, at its own launch.
        ENDPOINT="\(endpoint.path)"

        while IFS= read -r line; do
          [ -z "$line" ] && continue
          [ -f "$ENDPOINT" ] || continue
          URL=$(sed -n '1p' "$ENDPOINT")
          TOKEN=$(sed -n '2p' "$ENDPOINT")
          [ -z "$URL" ] && continue
          RESP=$(printf '%s' "$line" | /usr/bin/curl -s -m 120 -X POST "$URL" \\
            -H "Authorization: Bearer $TOKEN" \\
            -H "Content-Type: application/json" \\
            --data-binary @-)
          # A notification produces no reply; printing an empty line would
          # desynchronise the stream.
          [ -n "$RESP" ] && printf '%s\\n' "$RESP"
        done
        """
    }

    // MARK: - Reconcile

    /// Publish the endpoint, refresh the shim, and register with Claude Desktop.
    /// Safe to call on every launch and whenever the bound port changes.
    @discardableResult
    static func reconcile(port: UInt16, token: String) -> Bool {
        guard port != 0, !token.isEmpty else { return false }

        // 1. Endpoint file — two lines, 0600.
        let endpoint = "http://127.0.0.1:\(port)/mcp\n\(token)\n"
        do {
            try endpoint.write(to: endpointFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: endpointFile.path)
        } catch { return false }

        // 2. Shim — rewritten when stale so a Mira update can fix a bug in it
        //    without the user having to re-add the connector.
        let script = shimScript(endpoint: endpointFile)
        let existing = try? String(contentsOf: shimFile, encoding: .utf8)
        if existing != script {
            do {
                try script.write(to: shimFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                      ofItemAtPath: shimFile.path)
            } catch { return false }
        }

        // 3. Claude Desktop's config.
        return register()
    }

    /// Adds `mcpServers.mira`, preserving everything else in the file.
    ///
    /// This config holds the user's Cowork paths, trusted folders and account
    /// preferences. Same rule as ~/.claude.json: parse, change one key, write
    /// atomically, keep a backup — and if it cannot be parsed, do NOTHING rather
    /// than replace it with something Mira invented.
    @discardableResult
    private static func register() -> Bool {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        let desired: [String: Any] = [
            "command": "/bin/sh",
            "args": [shimFile.path]
        ]

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers["mira"] as? [String: Any],
           (existing["args"] as? [String])?.first == shimFile.path {
            return true   // already registered; don't rewrite the user's file
        }
        servers["mira"] = desired
        root["mcpServers"] = servers

        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return false }

        let backup = url.appendingPathExtension("mira-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? data.write(to: backup)
        }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    /// True when Claude Desktop is pointed at Mira. Note this says nothing about
    /// whether Claude Desktop has RESTARTED since — it reads its config at
    /// launch, so a fresh registration is not live until it does.
    static var isRegistered: Bool {
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return false }
        return servers["mira"] != nil
    }

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
}
