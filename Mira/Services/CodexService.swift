import Foundation

// CodexService — wraps the OpenAI Codex CLI (npm install -g @openai/codex).
// Mira uses Codex as a second coding agent lane alongside Claude Code / run_coding_agent.
// Detection is lazy (first call); subsequent calls use the cached binary path.
// All shell calls run through PythonSkillRunner.shellRun so the same zsh -lc contract applies.

@MainActor
final class CodexService {
    static let shared = CodexService()
    private init() {}

    struct CodexResult {
        let success:  Bool
        let output:   String
        let exitCode: Int
    }

    // Cache binary path so `which codex` only runs once per session.
    private var cachedBinPath: String? = nil
    private var checkedInstall = false

    // MARK: - Public API

    /// Runs `codex exec "<prompt>" --full-auto` in print mode.
    /// Requires git init in workdir (Codex refuses non-git directories).
    /// Falls back gracefully if Codex is not installed.
    func run(prompt: String, workdir: String? = nil) async -> CodexResult {
        guard let bin = await resolveBinary() else {
            return CodexResult(success: false,
                               output: "Codex CLI not found. Install: npm install -g @openai/codex",
                               exitCode: 127)
        }

        // Determine working directory — use provided path, current project dir, or a temp git repo.
        let wd: String
        if let provided = workdir, !provided.isEmpty {
            wd = provided
        } else {
            let agentFolder = UserDefaults.standard.string(forKey: "mira_agent_folder")
                ?? (NSHomeDirectory() + "/Desktop/Mira")
            wd = agentFolder
        }

        // Ensure directory exists and has a git repo (Codex requires it).
        let ensureGit = """
            mkdir -p \(wd.shellEscaped) && \
            cd \(wd.shellEscaped) && \
            (git rev-parse --git-dir >/dev/null 2>&1 || git init -q)
            """
        _ = await PythonSkillRunner.shared.shellRun(ensureGit, timeout: 10)

        // Run Codex in full-auto exec mode.
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd \(wd.shellEscaped) && \(bin.shellEscaped) exec '\(escapedPrompt)' --full-auto 2>&1"
        let raw = await PythonSkillRunner.shared.shellRun(cmd, timeout: 120)

        let success = !raw.lowercased().contains("error:") && !raw.isEmpty
        return CodexResult(success: success, output: raw, exitCode: success ? 0 : 1)
    }

    /// Check if Codex is installed without running a task.
    func isInstalled() async -> Bool {
        return await resolveBinary() != nil
    }

    /// Returns install/auth status for display in Settings or diagnostics.
    func statusSummary() async -> String {
        guard let bin = await resolveBinary() else {
            return "Not installed — run: npm install -g @openai/codex"
        }
        // Check auth by running a harmless version flag
        let version = await PythonSkillRunner.shared.shellRun("\(bin.shellEscaped) --version 2>&1", timeout: 8)
        let hasKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
        let authStatus = hasKey ? "auth OK" : "no OPENAI_API_KEY — run: codex auth login"
        return "Codex \(version.trimmingCharacters(in: .whitespacesAndNewlines)) · \(authStatus)"
    }

    // MARK: - Internal

    private func resolveBinary() async -> String? {
        if checkedInstall { return cachedBinPath }
        checkedInstall = true
        let result = await PythonSkillRunner.shared.shellRun("which codex 2>/dev/null", timeout: 5)
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedBinPath = path.isEmpty ? nil : path
        return cachedBinPath
    }
}

private extension String {
    var shellEscaped: String { "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'" }
}
