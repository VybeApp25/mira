import Foundation

// Runs bundled Python scripts from Resources/PythonSkills/.
// Manages a dedicated venv in Application Support to keep deps isolated from the user's environment.
// On first use per skill the required packages are installed; subsequent calls are fast.

@MainActor
final class PythonSkillRunner {
    static let shared = PythonSkillRunner()
    private init() {}

    // MARK: - Deps per skill

    private static let skillDeps: [String: [String]] = [
        "pdf_extract":       ["pdfplumber"],
        "docx_rw":           ["python-docx"],
        "sheet_rw":          ["openpyxl"],
        "youtube_transcript":["youtube-transcript-api"],
        "ocr_image":         ["pytesseract", "Pillow"],
        "imessage_read":     [],   // stdlib only (sqlite3, datetime)
        "findmy_devices":    [],   // stdlib only (sqlite3, protobuf manual decode)
        "reminders_rw":     [],   // stdlib only (osascript subprocess)
        "notes_rw":         [],   // stdlib only (osascript subprocess)
        "pptx_rw":          ["python-pptx"],
        "diagram_gen":      [],   // stdlib only (HTML generation)
        "obsidian_rw":      [],   // stdlib only (pathlib, re)
        "polymarket":       [],   // stdlib only (urllib)
        "maps":             [],   // stdlib only (urllib, OpenStreetMap/OSRM)
    ]

    // MARK: - Paths

    private let venvRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Mira/python-skills-venv")
    }()

    private var pythonBin: String { venvRoot.appendingPathComponent("bin/python3").path }
    private var pipBin:    String { venvRoot.appendingPathComponent("bin/pip3").path }

    // Track which skills have had their deps verified this session to avoid repeat checks.
    private var depsVerified: Set<String> = []

    // MARK: - Public API

    /// Run a named bundled skill with JSON-serializable args. Returns the script's JSON output.
    func run(skill: String, args: [String: Any]) async -> [String: Any] {
        // The scripts live under Resources/PythonSkills in the source tree, but
        // Copy-Bundle-Resources flattens non-folder-reference resources to the
        // Resources root — so look in the subdirectory first, then fall back to the
        // flat location. (Without the fallback, every skill fails to resolve in a
        // build where the folder isn't a preserved folder reference.)
        guard let scriptURL = Bundle.main.url(forResource: skill, withExtension: "py",
                                              subdirectory: "PythonSkills")
                ?? Bundle.main.url(forResource: skill, withExtension: "py") else {
            return ["success": false, "error": "Bundled skill '\(skill)' not found"]
        }

        await setupVenvIfNeeded()
        await ensureDeps(for: skill)

        // Write args to a temp file and pipe to stdin
        let tmpDir  = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("mira_skill_\(UUID().uuidString).json")
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let _    = try? data.write(to: tmpFile) else {
            return ["success": false, "error": "Could not serialise args"]
        }
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let cmd = "\(pythonBin.shellEscaped) \(scriptURL.path.shellEscaped) < \(tmpFile.path.shellEscaped)"
        let raw = await shellRun(cmd, timeout: 60)

        // Try to parse JSON from first complete JSON object in output
        if let jsonStart = raw.firstIndex(of: "{"),
           let jsonData  = String(raw[jsonStart...]).data(using: .utf8),
           let result    = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return result
        }
        return ["success": false, "error": "Non-JSON output: \(String(raw.prefix(400)))"]
    }

    // MARK: - Venv setup

    private func setupVenvIfNeeded() async {
        guard !FileManager.default.fileExists(atPath: pythonBin) else { return }
        try? FileManager.default.createDirectory(at: venvRoot.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        _ = await shellRun("python3 -m venv \(venvRoot.path.shellEscaped)", timeout: 30)
    }

    private func ensureDeps(for skill: String) async {
        guard !depsVerified.contains(skill),
              let deps = Self.skillDeps[skill], !deps.isEmpty else { return }
        // List installed packages once, install any missing
        let installed = await shellRun("\(pipBin.shellEscaped) list --format=freeze 2>/dev/null", timeout: 10)
        let lower = installed.lowercased()
        let missing = deps.filter { pkg in
            // Match on the first hyphen-separated component (e.g. "youtube-transcript-api" → "youtube")
            let key = pkg.components(separatedBy: "-").first ?? pkg
            return !lower.contains(key.lowercased())
        }
        if !missing.isEmpty {
            _ = await shellRun("\(pipBin.shellEscaped) install \(missing.joined(separator: " ")) -q", timeout: 120)
        }
        depsVerified.insert(skill)
    }

    // MARK: - Shell helper

    func shellRun(_ command: String, timeout: Int) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.launchPath = "/bin/zsh"
                proc.arguments  = ["-lc", command]   // -l so PATH includes /opt/homebrew/bin etc.
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                let kill = DispatchWorkItem { proc.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: kill)
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    kill.cancel()
                } catch {
                    kill.cancel()
                    cont.resume(returning: "error: \(error.localizedDescription)")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out  = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

private extension String {
    var shellEscaped: String { "'\(self.replacingOccurrences(of: "'", with: "'\\''"))'" }
}
