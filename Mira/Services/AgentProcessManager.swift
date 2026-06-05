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

    private var process:       Process?
    private var shouldRestart  = false
    private var nodePath:      String?
    private var scriptPath:    String?

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
                NSLog("[Mira] AgentProcessManager: process exited (code %d) — restarting in 2s",
                      p.terminationStatus)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.launch()
            }
        }

        do {
            try proc.run()
            process   = proc
            isRunning = true
            NSLog("[Mira] AgentProcessManager: started (pid %d) using %@",
                  proc.processIdentifier, node)
        } catch {
            NSLog("[Mira] AgentProcessManager: launch failed — %@", error.localizedDescription)
        }
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
