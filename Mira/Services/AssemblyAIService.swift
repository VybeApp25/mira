import Foundation

// AssemblyAI transcription service — pre-recorded audio only.
// For real-time voice Mira uses OpenAI Realtime; this handles file transcription.

enum AssemblyAIError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionError(String)
    case timeout
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let m):      return "Upload failed: \(m)"
        case .submissionFailed(let m):  return "Submission failed: \(m)"
        case .transcriptionError(let m):return "Transcription error: \(m)"
        case .timeout:                  return "Transcription timed out"
        case .invalidFile:              return "Could not read audio file"
        }
    }
}

struct TranscriptResult {
    let text: String
    let words: [TranscriptWord]
    let utterances: [Utterance]?
    let durationSeconds: Double?
}

struct TranscriptWord {
    let text: String
    let start: Int      // milliseconds
    let end:   Int
    let confidence: Double
}

struct Utterance {
    let speaker: String
    let text: String
    let start: Int
    let end:   Int
}

@MainActor
final class AssemblyAIService: ObservableObject {
    static let shared = AssemblyAIService()

    @Published private(set) var isTranscribing = false
    @Published private(set) var progress: String = ""

    private let apiKey  = AppSecrets.assemblyAIKey
    // Path-forwarding proxy when enabled, else AssemblyAI directly.
    private var baseURL: String { MiraBackend.assemblyAIBaseURL }

    private init() {}

    // MARK: - Transcribe a local file

    func transcribe(
        fileURL: URL,
        speakerLabels: Bool = false,
        languageCode: String? = nil
    ) async throws -> TranscriptResult {
        isTranscribing = true
        progress = "Uploading…"
        defer { isTranscribing = false; progress = "" }

        let uploadURL = try await upload(fileURL: fileURL)

        progress = "Submitting…"
        let transcriptId = try await submit(
            audioURL: uploadURL,
            speakerLabels: speakerLabels,
            languageCode: languageCode
        )

        progress = "Transcribing…"
        let result = try await poll(transcriptId: transcriptId)
        PostHogService.shared.capture("transcription_complete", properties: [
            "speaker_labels": speakerLabels ? "true" : "false"
        ])
        return result
    }

    // MARK: - Transcribe a remote URL

    func transcribe(
        audioURL: String,
        speakerLabels: Bool = false,
        languageCode: String? = nil
    ) async throws -> TranscriptResult {
        isTranscribing = true
        progress = "Submitting…"
        defer { isTranscribing = false; progress = "" }

        let transcriptId = try await submit(
            audioURL: audioURL,
            speakerLabels: speakerLabels,
            languageCode: languageCode
        )

        progress = "Transcribing…"
        return try await poll(transcriptId: transcriptId)
    }

    // MARK: - Upload

    private func upload(fileURL: URL) async throws -> String {
        guard let data = try? Data(contentsOf: fileURL) else { throw AssemblyAIError.invalidFile }
        guard let url = URL(string: "\(baseURL)/v2/upload") else { throw AssemblyAIError.uploadFailed("bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        MiraBackend.authorizeAssemblyAI(&req, directKey: apiKey)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AssemblyAIError.uploadFailed(String(data: respData, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let uploadURL = json["upload_url"] as? String else {
            throw AssemblyAIError.uploadFailed("No upload_url in response")
        }
        return uploadURL
    }

    // MARK: - Submit

    private func submit(audioURL: String, speakerLabels: Bool, languageCode: String?) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v2/transcript") else {
            throw AssemblyAIError.submissionFailed("bad URL")
        }

        var body: [String: Any] = [
            "audio_url":    audioURL,
            "speech_models": ["universal-3-pro", "universal-2"],
            "speaker_labels": speakerLabels
        ]
        if let lc = languageCode { body["language_code"] = lc }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        MiraBackend.authorizeAssemblyAI(&req, directKey: apiKey)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AssemblyAIError.submissionFailed(String(data: respData, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = json["id"] as? String else {
            throw AssemblyAIError.submissionFailed("No id in response")
        }
        return id
    }

    // MARK: - Poll

    private func poll(transcriptId: String) async throws -> TranscriptResult {
        guard let url = URL(string: "\(baseURL)/v2/transcript/\(transcriptId)") else {
            throw AssemblyAIError.submissionFailed("bad URL")
        }
        var req = URLRequest(url: url)
        MiraBackend.authorizeAssemblyAI(&req, directKey: apiKey)

        let deadline = Date().addingTimeInterval(300) // 5-minute timeout
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 s
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let status = json["status"] as? String ?? ""
            switch status {
            case "completed":
                return try parseResult(from: json)
            case "error":
                throw AssemblyAIError.transcriptionError(json["error"] as? String ?? "Unknown")
            default:
                continue
            }
        }
        throw AssemblyAIError.timeout
    }

    // MARK: - Parse

    private func parseResult(from json: [String: Any]) throws -> TranscriptResult {
        let text = json["text"] as? String ?? ""
        let duration = json["audio_duration"] as? Double

        let words: [TranscriptWord] = (json["words"] as? [[String: Any]] ?? []).compactMap { w in
            guard let t = w["text"] as? String,
                  let s = w["start"] as? Int,
                  let e = w["end"]   as? Int else { return nil }
            return TranscriptWord(text: t, start: s, end: e,
                                  confidence: w["confidence"] as? Double ?? 1.0)
        }

        let utterances: [Utterance]? = (json["utterances"] as? [[String: Any]])?.compactMap { u in
            guard let speaker = u["speaker"] as? String,
                  let t = u["text"] as? String,
                  let s = u["start"] as? Int,
                  let e = u["end"]   as? Int else { return nil }
            return Utterance(speaker: speaker, text: t, start: s, end: e)
        }

        return TranscriptResult(text: text, words: words, utterances: utterances, durationSeconds: duration)
    }
}
