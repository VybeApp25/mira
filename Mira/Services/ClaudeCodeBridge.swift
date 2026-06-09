import Foundation

// MARK: - Models

struct ClaudeCodeArtifact: Identifiable {
    let id       = UUID()
    let filename:  String
    let content:   String
    let language:  String   // swift, python, md, etc.

    var displayName: String { URL(fileURLWithPath: filename).lastPathComponent }
    var icon: String {
        switch language.lowercased() {
        case "swift":            return "swift"
        case "python", "py":     return "chevron.left.forwardslash.chevron.right"
        case "javascript", "js", "typescript", "ts": return "curlybraces"
        case "md", "markdown":   return "doc.text"
        case "json":             return "curlybraces.square"
        case "sh", "bash":       return "terminal"
        case "html":             return "globe"
        case "css":              return "paintbrush"
        default:                 return "doc.badge.gearshape"
        }
    }
}

struct ClaudeCodeResult {
    let text:      String
    let artifacts: [ClaudeCodeArtifact]
    let costUSD:   Double
}

// MARK: - Bridge

/// Runs `claude -p` headlessly and streams JSON events back to the caller.
/// Mirrors HeyClicky's ClickyLocalRootToolExecutor / ShellOutcome pattern.
@MainActor
final class ClaudeCodeBridge {
    static let shared = ClaudeCodeBridge()
    private init() {}

    // Resolved at runtime; falls back to common install locations.
    private var claudeExecutable: String {
        let candidates = [
            "/Users/\(NSUserName())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? candidates[0]
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: claudeExecutable)
    }

    // MARK: - Run

    /// Streams text tokens via `onToken` as Claude Code responds,
    /// then returns the full result + any file artifacts on completion.
    func run(
        prompt:    String,
        workdir:   String?               = nil,
        onToken:   @escaping (String) -> Void = { _ in },
        onArtifact:@escaping (ClaudeCodeArtifact) -> Void = { _ in }
    ) async throws -> ClaudeCodeResult {

        let cwd = workdir
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeExecutable)
        process.arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        try process.run()

        var fullText  = ""
        var costUSD   = 0.0
        var artifacts: [ClaudeCodeArtifact] = []
        var createdFiles: Set<String> = []

        for try await line in outPipe.fileHandleForReading.bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch json["type"] as? String ?? "" {

            case "assistant":
                guard let msg     = json["message"] as? [String: Any],
                      let content = msg["content"]  as? [[String: Any]] else { break }
                for item in content {
                    guard item["type"] as? String == "text",
                          let chunk = item["text"] as? String else { continue }
                    fullText += chunk
                    let captured = chunk
                    await MainActor.run { onToken(captured) }
                }

            case "tool_result", "tool_use":
                // Capture Write / Edit tool results to build artifact list
                parseToolEvent(json, into: &createdFiles)

            case "result":
                if let c = json["total_cost_usd"] as? Double { costUSD = c }
                // Final text lives in "result" field if assistant events were empty
                if fullText.isEmpty, let r = json["result"] as? String { fullText = r }

            default: break
            }
        }

        process.waitUntilExit()

        // Resolve created files into artifacts
        for path in createdFiles.sorted() {
            let url  = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                           : URL(fileURLWithPath: cwd).appendingPathComponent(path)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let ext  = url.pathExtension.lowercased()
                let art  = ClaudeCodeArtifact(filename: path, content: content, language: ext)
                artifacts.append(art)
                let captured = art
                await MainActor.run { onArtifact(captured) }
            }
        }

        return ClaudeCodeResult(text: fullText, artifacts: artifacts, costUSD: costUSD)
    }

    // MARK: - Tool event parsing

    private func parseToolEvent(_ json: [String: Any], into files: inout Set<String>) {
        // Look for "Write" or "Edit" tool_use events — they carry a "file_path" param
        if let name = json["name"] as? String,
           (name == "Write" || name == "Edit" || name == "MultiEdit"),
           let input = json["input"] as? [String: Any],
           let path  = input["file_path"] as? String {
            files.insert(path)
        }
        // tool_result wrapping
        if let content = json["content"] as? [[String: Any]] {
            for item in content {
                if let nested = item["content"] as? [String: Any] {
                    parseToolEvent(nested, into: &files)
                }
            }
        }
    }
}
