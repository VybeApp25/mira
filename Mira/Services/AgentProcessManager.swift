// AgentProcessManager.swift
// Launches the bundled Node.js agent server (Resources/server.js) as a child process.
// Keys are passed via environment — no .env file needed.
// Auto-restarts on crash; terminates cleanly when the app quits.

import Foundation

@MainActor
final class AgentProcessManager {

    static let shared = AgentProcessManager()
    private init() {}

    @Published private(set) var isRunning = false

    private var process:        Process?
    private var shouldRestart   = false
    private var nodePath:       String?
    private var scriptPath:     String?
    private var restartAttempts = 0
    private var lastLaunchDate  = Date.distantPast

    private static let agentPort = 4242

    // MARK: - Public API

    func start() {
        shouldRestart = true

        guard let node = resolveNode() else {
            NSLog("[Mira] AgentProcessManager: Node.js not found — integrations unavailable.")
            return
        }
        guard let script = Bundle.main.path(forResource: "server", ofType: "js") else {
            NSLog("[Mira] AgentProcessManager: server.js missing from app bundle.")
            return
        }

        nodePath   = node
        scriptPath = script
        launch()
    }

    func stop() {
        shouldRestart = false
        process?.terminate()
        process   = nil
        isRunning = false
    }

    // MARK: - Internal

    private func launch() {
        guard let node = nodePath, let script = scriptPath else { return }

        // A sidecar orphaned by a previous Mira run (e.g. the installed app's
        // GUI died but its node child survived) keeps the port bound, so every
        // fresh launch exits immediately and we restart-loop forever.
        reapOrphanSidecar()

        let proc = Process()
        proc.launchPath = node
        proc.arguments  = [script]
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "COMPOSIO_API_KEY":  AppSecrets.composioAPIKey,
            "ANTHROPIC_API_KEY": AppSecrets.anthropicAPIKey,
        ]) { _, new in new }

        // Silence stdout/stderr — logs only go to Console.app via NSLog from Swift side.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRestart else { return }
                self.isRunning = false
                // A long uptime means this was a real crash, not a launch
                // failure — reset the rapid-exit counter.
                if Date().timeIntervalSince(self.lastLaunchDate) > 60 {
                    self.restartAttempts = 0
                }
                self.restartAttempts += 1
                guard self.restartAttempts <= 5 else {
                    NSLog("[Mira] AgentProcessManager: 5 rapid exits — giving up. Check port %d and server.js.",
                          Self.agentPort)
                    return
                }
                let delay = min(pow(2.0, Double(self.restartAttempts)), 30.0)
                NSLog("[Mira] AgentProcessManager: process exited (code %d) — restart %d/5 in %.0fs",
                      p.terminationStatus, self.restartAttempts, delay)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self.launch()
            }
        }

        do {
            try proc.run()
            process        = proc
            isRunning      = true
            lastLaunchDate = Date()
            NSLog("[Mira] AgentProcessManager: started (pid %d) using %@",
                  proc.processIdentifier, node)
        } catch {
            NSLog("[Mira] AgentProcessManager: launch failed — %@", error.localizedDescription)
        }
    }

    /// Kills any *Mira* sidecar left listening on the agent port by a previous
    /// run. Only PIDs whose command line contains Mira's server.js are touched —
    /// an unrelated app on the port is logged, never killed.
    private func reapOrphanSidecar() {
        guard let pids = shellOutput("/usr/sbin/lsof", ["-ti", ":\(Self.agentPort)"]) else { return }
        var reaped = false
        for line in pids.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
                  pid != process?.processIdentifier else { continue }
            let cmd = shellOutput("/bin/ps", ["-p", "\(pid)", "-o", "command="]) ?? ""
            if cmd.contains("server.js") && cmd.contains("Mira") {
                NSLog("[Mira] AgentProcessManager: reaping orphan sidecar pid %d", pid)
                kill(pid, SIGTERM)
                reaped = true
            } else if !cmd.isEmpty {
                NSLog("[Mira] AgentProcessManager: port %d held by non-Mira process: %@",
                      Self.agentPort, cmd)
            }
        }
        if reaped { usleep(400_000) }   // let the kernel release the port
    }

    private func shellOutput(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = path
        proc.arguments  = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Find node

    private func resolveNode() -> String? {
        // Check well-known install locations first (no shell needed).
        let candidates = [
            "/opt/homebrew/bin/node",   // M-series Homebrew
            "/usr/local/bin/node",      // Intel Homebrew
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }

        // Fall back to a login shell `which node` — picks up nvm, volta, etc.
        let proc = Process()
        proc.launchPath = "/bin/zsh"
        proc.arguments  = ["-l", "-c", "which node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }
}
