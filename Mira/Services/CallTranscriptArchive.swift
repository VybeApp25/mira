import Foundation

// MARK: - CallTranscriptArchive
//
// Phase E: persist a finished call transcript and let Mira summarize it.
// Saves Markdown to the user's chosen folder (default ~/Documents/Transcripts),
// creating it if needed. Summaries are generated with Claude and appended to the
// same file, so the saved transcript is self-contained and Mira-readable.

enum CallTranscriptArchive {
    static let folderKey = "mira_transcript_folder"

    /// User-chosen save folder, defaulting to ~/Documents/Transcripts.
    static func folderURL() -> URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Transcripts", isDirectory: true)
    }

    /// Write the transcript as Markdown, creating the folder if needed.
    @discardableResult
    static func save(_ s: CallTranscriptSnapshot) -> URL? {
        let folder = folderURL()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("[Transcript] create folder failed: \(error.localizedDescription)")
            return nil
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        let url = folder.appendingPathComponent("\(s.source.displayName) - \(stamp.string(from: s.startedAt)).md")
        do {
            try markdown(s).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("[Transcript] save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Human-readable transcript body (also what we feed Claude to summarize).
    static func plainText(_ s: CallTranscriptSnapshot) -> String {
        s.segments
            .map { "\($0.speaker == .me ? "You" : s.source.displayName): \($0.text)" }
            .joined(separator: "\n")
    }

    private static func markdown(_ s: CallTranscriptSnapshot) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let mins = Int(s.duration) / 60, secs = Int(s.duration) % 60
        var out = "# \(s.source.displayName) call — \(df.string(from: s.startedAt))\n"
        out += "_Duration \(mins)m \(secs)s · \(s.segments.count) lines_\n\n"
        for seg in s.segments {
            out += "**\(seg.speaker == .me ? "You" : s.source.displayName):** \(seg.text)\n\n"
        }
        return out
    }

    /// Summarize the transcript with Claude. Returns the summary and appends it to
    /// the saved file (so the .md ends up holding transcript + summary).
    static func summarize(_ s: CallTranscriptSnapshot, fileURL: URL?) async -> String? {
        let body = plainText(s)
        guard !body.isEmpty else { return nil }

        let key = await MainActor.run { MiraState.shared?.effectiveAPIKey ?? AppSecrets.anthropicAPIKey }
        guard !key.isEmpty else { return nil }

        let prompt = """
        Summarize this call transcript for the participant. Give a 2–3 sentence \
        overview, then bullet the key points and any action items or follow-ups. \
        Be concise.

        \(body)
        """
        do {
            let summary = try await ClaudeService(apiKey: key).ask(prompt: prompt)
            if let fileURL,
               let data = "\n\n---\n\n## Summary\n\n\(summary)\n".data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
            return summary
        } catch {
            NSLog("[Transcript] summarize failed: \(error.localizedDescription)")
            return nil
        }
    }
}
