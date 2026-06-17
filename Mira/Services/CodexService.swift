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

    /// Runs `codex exec "<prompt>" --full-auto`, judging success by the process
    /// EXIT CODE (not by scanning output for "error:", which falsely failed any
    /// task whose result legitimately mentions an error). The clean final agent
    /// message is captured via `-o <file>` so the reply isn't polluted by log
    /// noise. Requires git in workdir (Codex needs it for diffs/apply).
    ///
    /// `model` selects the Codex model (cost/speed lever); nil falls back to the
    /// `mira_codex_model` default, and an empty default uses Codex's own default
    /// — so this never references a model the account may not have.
    /// `timeout` defaults to 10 min (real coding tasks exceed the old 120 s).
    func run(prompt: String, workdir: String? = nil,
             model: String? = nil, timeout: TimeInterval = 600) async -> CodexResult {
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

        // Clean final-message sink (`-o`). Unique per run so concurrent/old runs
        // can't leak each other's output.
        let lastMsgPath = NSTemporaryDirectory() + "codex-last-\(UUID().uuidString).txt"

        // Optional model lever — only passed when explicitly configured.
        let chosenModel = model ?? UserDefaults.standard.string(forKey: "mira_codex_model")
        let modelFlag = (chosenModel?.isEmpty == false) ? " -m \(chosenModel!.shellEscaped)" : ""

        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd \(wd.shellEscaped) && \(bin.shellEscaped) exec '\(escapedPrompt)'"
            + " --full-auto\(modelFlag) -o \(lastMsgPath.shellEscaped) 2>&1"

        let run = await runProcess(cmd, timeout: timeout)

        // Prefer the clean `-o` final message; fall back to captured stdout.
        let finalMsg = (try? String(contentsOfFile: lastMsgPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(atPath: lastMsgPath)

        let success = run.exitCode == 0
        let output: String
        if !finalMsg.isEmpty {
            output = finalMsg
        } else if run.timedOut {
            output = "Codex timed out after \(Int(timeout))s."
        } else {
            output = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return CodexResult(success: success, output: output, exitCode: Int(run.exitCode))
    }

    // MARK: - Process runner

    private struct ProcRun { let exitCode: Int32; let stdout: String; let timedOut: Bool }

    /// Runs a command in a login shell (so the nvm-installed `codex` is on PATH),
    /// draining output non-blockingly and enforcing a hard timeout via terminate.
    private func runProcess(_ command: String, timeout: TimeInterval) async -> ProcRun {
        let proc = Process()
        proc.launchPath = "/bin/zsh"
        proc.arguments  = ["-lc", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe

        do { try proc.run() }
        catch { return ProcRun(exitCode: 127, stdout: "Failed to launch Codex: \(error.localizedDescription)", timedOut: false) }

        // Watchdog: terminate if the task overruns the timeout.
        var timedOut = false
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if proc.isRunning { timedOut = true; proc.terminate() }
        }

        // Drain stdout/stderr without blocking the main actor (keeps the pipe from
        // filling and deadlocking the child). Cap retained text for diagnostics.
        var collected = ""
        if let lines = try? await collectLines(pipe.fileHandleForReading) { collected = lines }

        proc.waitUntilExit()
        watchdog.cancel()
        return ProcRun(exitCode: proc.terminationStatus, stdout: String(collected.suffix(4000)), timedOut: timedOut)
    }

    private func collectLines(_ handle: FileHandle) async throws -> String {
        var out = ""
        for try await line in handle.bytes.lines { out += line + "\n" }
        return out
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
