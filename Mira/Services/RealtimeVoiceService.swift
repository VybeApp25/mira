// RealtimeVoiceService.swift
// OpenAI Realtime API (gpt-4o-realtime-preview) — true speech-to-speech over WebSocket.
// Pipeline: AVAudioEngine mic → PCM16 → WebSocket → PCM16 → AVAudioPlayerNode
// Barge-in handled by server-side VAD; cancel response + drain player on speech_started.

import Foundation
@preconcurrency import AVFoundation

// MARK: - Voice options (OpenAI Realtime API voices)

enum MiraVoice: String, CaseIterable, Identifiable {
    case alloy   = "alloy"
    case ash     = "ash"
    case ballad  = "ballad"
    case coral   = "coral"
    case echo    = "echo"
    case shimmer = "shimmer"
    case verse   = "verse"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alloy:   return "Alloy — Neutral"
        case .ash:     return "Ash — Calm"
        case .ballad:  return "Ballad — Warm"
        case .coral:   return "Coral — Bright"
        case .echo:    return "Echo — Crisp"
        case .shimmer: return "Shimmer — Soft"
        case .verse:   return "Verse — Expressive"
        }
    }

    static var saved: MiraVoice {
        get { MiraVoice(rawValue: UserDefaults.standard.string(forKey: "mira_voice") ?? "alloy") ?? .alloy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mira_voice") }
    }
}

// MARK: - State

enum RealtimeState: Equatable {
    case idle
    case connecting
    case recording      // connected + VAD active, waiting for user speech
    case transcribing   // reused for brief connecting UI label
    case thinking       // response generating, before first audio chunk
    case speaking       // AI audio streaming / playing
    case error(String)
}

// MARK: - Realtime voice service

@MainActor
final class RealtimeVoiceService: NSObject, ObservableObject {

    @Published var state:      RealtimeState = .idle
    @Published var userDraft:  String        = ""
    @Published var aiDraft:    String        = ""
    @Published var toolStatus: String        = ""   // e.g. "Opening Safari…"

    var onUserMessage: ((String) -> Void)?
    var onAIMessage:   ((String) -> Void)?

    // MARK: Private — WebSocket

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // MARK: Private — Audio capture (mic → API)

    private var captureEngine   = AVAudioEngine()
    private var inputConverter: AVAudioConverter?
    private let captureRate:    Double = 24_000   // Realtime API expects PCM16 @ 24 kHz

    // MARK: Private — Audio playback (API → speakers)

    private var playEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    // Float32 @ 24 kHz — AVAudioEngine resamples to hardware rate automatically
    private let playFmt    = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    // MARK: Private — Tool call assembly

    private var pendingCallId:   String = ""
    private var pendingToolName: String = ""
    private var pendingToolArgs: String = ""

    // MARK: Private — Transcript assembly

    private var aiTranscript: String = ""

    // MARK: Private — Session

    private var openAIKey       = ""
    private var shouldReconnect = false
    private var retryCount      = 0

    // MARK: - Public API

    func connect(openAIKey: String) {
        self.openAIKey    = openAIKey
        shouldReconnect   = true
        retryCount        = 0
        state             = .connecting
        openSocket()
    }

    func stop() {
        shouldReconnect = false
        retryCount      = 0
        teardown()
        state     = .idle
        userDraft = ""
        aiDraft   = ""
    }

    // MARK: - WebSocket lifecycle

    private func openSocket() {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2") else { return }
        var req = URLRequest(url: url)
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        // OpenAI-Beta header removed — required by GA API (beta removed May 2026)

        urlSession = URLSession(configuration: .default)
        webSocket  = urlSession?.webSocketTask(with: req)
        webSocket?.resume()
        pump()
    }

    private func pump() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    self.dispatch(msg)
                    self.pump()
                case .failure:
                    if self.shouldReconnect { self.scheduleReconnect() }
                }
            }
        }
    }

    // MARK: - Event dispatch

    private func dispatch(_ msg: URLSessionWebSocketTask.Message) {
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d):   text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:    return
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        handle(type: type, event: json)
    }

    // MARK: - Server event handler

    private func handle(type: String, event: [String: Any]) {
        switch type {

        // ── Session ready ──────────────────────────────────────────────────────
        case "session.created":
            retryCount = 0
            configureSession()
            startCapture()
            setupPlayback()
            state = .recording

        // ── Barge-in + context refresh at the start of each user turn ────────────
        case "input_audio_buffer.speech_started":
            if case .speaking = state {
                playerNode.stop()
                playerNode.reset()
                playerNode.play()           // ready for next response
                emit(["type": "response.cancel"])
            }
            userDraft = ""
            state     = .recording
            // Refresh context snapshot so every turn has the latest active app / URL / clipboard
            refreshContextInstructions()

        // ── User transcript (from Whisper transcription) ───────────────────────
        case "conversation.item.input_audio_transcription.completed":
            let text = event["transcript"] as? String ?? ""
            if !text.isEmpty { userDraft = text; onUserMessage?(text) }

        // ── Response lifecycle ─────────────────────────────────────────────────
        case "response.created":
            aiTranscript = ""
            aiDraft      = ""
            state        = .thinking

        // GA API event names (beta "response.audio.*" renamed to "response.output_audio.*")
        case "response.output_audio.delta":
            if let delta = event["delta"] as? String {
                enqueueAudio(delta)
                if case .thinking = state { state = .speaking }
            }

        case "response.output_audio.done":
            // Schedule a 1-sample sentinel; its completion fires when all prior audio drains.
            if let sentinel = AVAudioPCMBuffer(pcmFormat: playFmt, frameCapacity: 1) {
                sentinel.frameLength = 1
                sentinel.floatChannelData?[0][0] = 0.0
                playerNode.scheduleBuffer(sentinel) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, case .speaking = self.state else { return }
                        self.state   = .recording
                        self.aiDraft = ""
                    }
                }
            }

        case "response.output_audio_transcript.delta":
            let delta = event["delta"] as? String ?? ""
            aiTranscript += delta
            aiDraft       = aiTranscript

        case "response.output_audio_transcript.done":
            if !aiTranscript.isEmpty { onAIMessage?(aiTranscript) }

        // ── Tool call assembly ─────────────────────────────────────────────────
        case "response.output_item.added":
            if let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                pendingToolName = item["name"]    as? String ?? ""
                pendingCallId   = item["call_id"] as? String ?? ""
                pendingToolArgs = ""
                toolStatus = Self.toolLabel(for: pendingToolName)
            }

        case "response.function_call_arguments.delta":
            pendingToolArgs += event["delta"] as? String ?? ""

        case "response.function_call_arguments.done":
            let id   = event["call_id"]   as? String ?? pendingCallId
            let name = event["name"]      as? String ?? pendingToolName
            let args = event["arguments"] as? String ?? pendingToolArgs
            // Update status with specific args now that we have them
            toolStatus = Self.toolLabel(for: name, argsJSON: args)
            Task { await self.runTool(callId: id, name: name, argsJSON: args) }
            pendingCallId = ""; pendingToolName = ""; pendingToolArgs = ""

        // ── Error ──────────────────────────────────────────────────────────────
        case "error":
            let msg = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            state = .error(msg)
            if shouldReconnect { scheduleReconnect() }

        default: break
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        emit(buildSessionUpdate(includeFullConfig: true))
    }

    /// Sends a lightweight session.update to refresh instructions with the latest context snapshot.
    /// Called at the start of each user turn so context is always current.
    private func refreshContextInstructions() {
        emit(buildSessionUpdate(includeFullConfig: false))
    }

    private func buildSessionUpdate(includeFullConfig: Bool) -> [String: Any] {
        let contextBlock = ContextService.shared.buildPromptBlock()
        let instructions = MiraPrompts.realtimeSystem + "\n\n" + contextBlock

        var session: [String: Any] = [
            "type":         "realtime",
            "instructions": instructions,
        ]

        if includeFullConfig {
            session["modalities"]          = ["text", "audio"]
            session["voice"]               = MiraVoice.saved.rawValue
            session["input_audio_format"]  = "pcm16"
            session["output_audio_format"] = "pcm16"
            session["input_audio_transcription"] = ["model": "whisper-1"]
            session["turn_detection"] = [
                "type":                "server_vad",
                "threshold":           0.5,
                "prefix_padding_ms":   300,
                "silence_duration_ms": 600
            ] as [String: Any]
            session["tools"]       = MiraToolService.definitions
            session["tool_choice"] = "auto"
        }

        return ["type": "session.update", "session": session]
    }

    // MARK: - Audio capture (mic → PCM16 → WebSocket)

    private func startCapture() {
        captureEngine = AVAudioEngine()
        let node      = captureEngine.inputNode
        let hwFmt     = node.outputFormat(forBus: 0)

        // Converter: hardware format → Float32 @ 24 kHz mono
        let tgtFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate:  captureRate,
                                    channels:    1,
                                    interleaved: false)!
        inputConverter = AVAudioConverter(from: hwFmt, to: tgtFmt)

        node.installTap(onBus: 0, bufferSize: 4800, format: hwFmt) { [weak self] buf, _ in
            self?.encodeAndSend(buf)
        }
        captureEngine.prepare()
        try? captureEngine.start()
    }

    private func encodeAndSend(_ buffer: AVAudioPCMBuffer) {
        guard let conv = inputConverter else { return }
        let outFrames = AVAudioFrameCount(
            Double(buffer.frameLength) * captureRate / buffer.format.sampleRate
        )
        guard outFrames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat,
                                         frameCapacity: outFrames) else { return }
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let floats = out.floatChannelData?[0] else { return }

        let count  = Int(out.frameLength)
        var int16  = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            int16[i] = Int16(max(-32_768, min(32_767, Int32(floats[i] * 32_767))))
        }
        let base64 = Data(bytes: int16, count: count * 2).base64EncodedString()

        Task { @MainActor [weak self] in
            self?.emit(["type": "input_audio_buffer.append", "audio": base64])
        }
    }

    // MARK: - Audio playback (PCM16 from API → speakers)

    private func setupPlayback() {
        playEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playEngine.attach(playerNode)
        // Connect at 24 kHz — AVAudioEngine resamples to hardware rate transparently
        playEngine.connect(playerNode, to: playEngine.mainMixerNode, format: playFmt)
        try? playEngine.start()
        playerNode.play()
    }

    private func enqueueAudio(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let frames = data.count / 2   // 2 bytes per Int16 sample
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playFmt,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frames { dst[i] = Float(src[i]) / 32_768.0 }
        }
        playerNode.scheduleBuffer(buf)
    }

    // MARK: - Tool execution

    private func runTool(callId: String, name: String, argsJSON: String) async {
        let output = await MiraToolService.execute(name: name, argsJSON: argsJSON)
        toolStatus = ""
        emit([
            "type": "conversation.item.create",
            "item": [
                "type":    "function_call_output",
                "call_id": callId,
                "output":  output
            ] as [String: Any]
        ])
        emit(["type": "response.create"])
    }

    // MARK: - Tool status labels

    private static func toolLabel(for name: String, argsJSON: String = "") -> String {
        let args = (try? JSONSerialization.jsonObject(
            with: argsJSON.data(using: .utf8) ?? Data()
        ) as? [String: Any]) ?? [:]

        switch name {
        case "open_application":
            let app = args["app_name"] as? String ?? "app"
            return "Opening \(app)…"
        case "get_calendar_events":
            return "Checking your calendar…"
        case "control_music":
            let action = (args["action"] as? String ?? "controlling").capitalized
            return "\(action) music…"
        case "search_web":
            let q = args["query"] as? String ?? "the web"
            return "Searching for \"\(q)\"…"
        case "run_shortcut":
            let s = args["shortcut_name"] as? String ?? "shortcut"
            return "Running \"\(s)\"…"
        default:
            return "Working on it…"
        }
    }

    // MARK: - Live voice update

    /// Resends session.update with the current saved voice — call when user changes voice in Settings.
    func updateVoice() {
        guard webSocket != nil else { return }
        emit([
            "type": "session.update",
            "session": [
                "type":  "realtime",
                "voice": MiraVoice.saved.rawValue
            ] as [String: Any]
        ])
    }

    // MARK: - Reconnection (exponential backoff, max 5 attempts)

    private func scheduleReconnect() {
        guard retryCount < 5 else {
            state = .error("Connection lost — tap mic to reconnect.")
            return
        }
        let delay = pow(2.0, Double(retryCount))
        retryCount += 1
        state = .connecting
        teardown()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            openSocket()
        }
    }

    // MARK: - Teardown

    private func teardown() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket  = nil
        urlSession = nil

        if captureEngine.isRunning {
            captureEngine.inputNode.removeTap(onBus: 0)
            captureEngine.stop()
        }
        inputConverter = nil

        playerNode.stop()
        if playEngine.isRunning { playEngine.stop() }
    }

    // MARK: - WebSocket emit helper

    private func emit(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}
