// CodexBridgeConfig.swift
// Registers Mira's in-process MCP server (MiraMCPServer) with Codex by writing an
// [mcp_servers.mira] block into ~/.codex/config.toml. After this, `codex exec …` (and
// `codex mcp-server`) can discover Mira's tools. The bearer token is NOT written here —
// only the env-var NAME is — the secret is injected at spawn time via MIRA_MCP_TOKEN
// (see CodexComputerUseService / CodexService). Mira is not sandboxed, so we edit the
// file directly. Idempotent: replaces only the `mira` block, leaving vybe/plugins/projects
// untouched.

import Foundation

enum CodexBridgeConfig {

    static let tokenEnvVar = "MIRA_MCP_TOKEN"

    private static var configURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
    }

    /// Ensure ~/.codex/config.toml points Codex at Mira's MCP server on `port`.
    /// Safe to call repeatedly (e.g. every launch / whenever the bound port changes).
    static func reconcile(port: UInt16) {
        guard port != 0 else { return }
        let url = configURL
        let block = """
        [mcp_servers.mira]
        url = "http://127.0.0.1:\(port)/mcp"
        bearer_token_env_var = "\(tokenEnvVar)"
        """

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let stripped = removingMiraBlock(from: existing)

        // If the desired block is already present verbatim, nothing to do.
        if existing.contains("url = \"http://127.0.0.1:\(port)/mcp\"")
            && existing.contains("[mcp_servers.mira]") {
            return
        }

        var updated = stripped
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        if !updated.isEmpty { updated += "\n" }
        updated += block + "\n"

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            print("[CodexBridgeConfig] registered [mcp_servers.mira] → 127.0.0.1:\(port)")
        } catch {
            print("[CodexBridgeConfig] failed to write config.toml: \(error)")
        }
    }

    /// Remove an existing `[mcp_servers.mira]` table: the header line plus all following
    /// lines up to (but not including) the next top-level `[` table header or EOF.
    private static func removingMiraBlock(from toml: String) -> String {
        let lines = toml.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[mcp_servers.mira]" {
                skipping = true
                continue
            }
            if skipping {
                // A new table header ends the mira block.
                if trimmed.hasPrefix("[") { skipping = false } else { continue }
            }
            out.append(line)
        }
        // Trim trailing blank lines left behind by removal.
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
