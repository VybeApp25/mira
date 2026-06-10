// RealtimeVoiceService.swift
// Mirrors HeyClicky's RealtimeVoiceController + RealtimeVoiceClient architecture.
//
// Two modes:
//   • Always-on  — connectAlwaysOn() on app launch; server_vad auto-commits turns.
//   • Push-to-talk — beginPushToTalk() / endPushToTalk() with 400ms tail commit.
//
// Pipeline: AVAudioEngine mic → PCM16 @ 24 kHz → base64 → WebSocket
//           WebSocket → PCM16 → Float32 → AVAudioPlayerNode → speakers

import Foundation
@preconcurrency import AVFoundation

// MARK: - Voice options

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
    case recording      // session live, VAD active — user can speak at any time
    case transcribing   // unused slot kept for UI label compat
    case thinking       // response generating, before first audio chunk
    case speaking       // AI audio streaming / playing
    case error(String)
}

// MARK: - RealtimeVoiceService

@MainActor
final class RealtimeVoiceService: NSObject, ObservableObject {

    // App-lifetime singleton — mirrors HeyClicky's RealtimeVoiceController.shared
    static let shared = RealtimeVoiceService()

    @Published var state:                RealtimeState = .idle
    @Published var userDraft:            String        = ""
    @Published var aiDraft:              String        = ""
    @Published var toolStatus:           String        = ""
    @Published private(set) var isAlwaysOnActive: Bool = false

    // Audio power level visualization — 44-sample ring buffer, updated at ~70ms intervals.
    // Ported from farzaa/clicky BuddyDictationManager (MIT).
    @Published private(set) var audioPowerLevel:   CGFloat = 0
    @Published private(set) var audioPowerHistory: [CGFloat] = Array(repeating: 0.02, count: 44)

    private static let powerSampleInterval: TimeInterval = 0.07
    private var lastPowerSampleDate = Date.distantPast

    var onUserMessage: ((String) -> Void)?
    var onAIMessage:   ((String) -> Void)?

    // MARK: Private — WebSocket

    private var webSocket:  URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // MARK: Private — Audio capture (mic → API)

    private var captureEngine   = AVAudioEngine()
    private var inputConverter: AVAudioConverter?
    private let captureRate:    Double = 24_000

    // MARK: Private — Audio playback (API → speakers)

    private var playEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let playFmt    = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    // MARK: Private — Tool call assembly

    private var pendingCallId:   String = ""
    private var pendingToolName: String = ""
    private var pendingToolArgs: String = ""

    // MARK: Private — Transcript

    private var aiTranscript: String = ""

    // MARK: Private — Session

    private var openAIKey       = ""
    private var shouldReconnect = false
    private var retryCount      = 0
    private var reconnectTask:  Task<Void, Never>?

    // MARK: Private — Always-on

    private var isAlwaysOn = false
    // Suppresses VAD for a settle period after the response audio finishes.
    // Prevents speaker audio echoing back through the mic from triggering a new turn.
    private var suppressMicUntil: Date = .distantPast

    // MARK: Private — PTT (mirrors HeyClicky's pushToTalkTailCommitTask)

    private var pttActive:   Bool                = false
    private var pttTailTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start always-on listening — call once on app launch from NotchManager/AppDelegate.
    /// Mirrors HeyClicky's beginAlwaysOnListening().
    func connectAlwaysOn() {
        guard !isAlwaysOn else { return }
        isAlwaysOn       = true
        isAlwaysOnActive = true
        openAIKey        = AppSecrets.openAIKey
        shouldReconnect  = true
        retryCount       = 0
        state            = .connecting
        NSLog("[MiraRealtime] always-on start")
        openSocket()
    }

    /// Tear down always-on session — call on app quit.
    func disconnectAlwaysOn() {
        guard isAlwaysOn else { return }
        isAlwaysOn       = false
        isAlwaysOnActive = false
        stop()
    }

    /// Legacy connect — still called by any stale code paths.
    func connect(openAIKey: String) {
        guard case .idle = state else { return }
        self.openAIKey  = openAIKey
        shouldReconnect = true
        retryCount      = 0
        state           = .connecting
        openSocket()
    }

    /// Full stop — tears down session and resets state.
    func stop() {
        shouldReconnect  = false
        retryCount       = 0
        pttActive        = false
        reconnectTask?.cancel(); reconnectTask = nil
        pttTailTask?.cancel();   pttTailTask   = nil
        teardown()
        state     = .idle
        userDraft = ""
        aiDraft   = ""
    }

    // MARK: - Push-to-Talk (mirrors HeyClicky's beginPushToTalk / PTT end tail)

    /// Called when PTT hotkey is pressed down.
    func beginPushToTalk() {
        // Cancel any pending tail from a previous PTT
        pttTailTask?.cancel(); pttTailTask = nil
        pttActive = true
        NSLog("[MiraRealtime] PTT begin: active=%@ socket=%@",
              pttActive ? "YES" : "NO",
              webSocket != nil ? "live" : "nil")

        if webSocket != nil {
            // Reuse healthy always-on session (mic already streaming)
            NSLog("[MiraRealtime] PTT begin: reusing healthy session")
        } else {
            // Open fresh session for PTT-only mode
            openAIKey       = AppSecrets.openAIKey
            shouldReconnect = true
            retryCount      = 0
            state           = .connecting
            openSocket()
        }
    }

    /// Called when PTT hotkey is released — 400ms tail then manual commit.
    func endPushToTalk() {
        guard pttActive else { return }
        pttActive = false
        NSLog("[MiraRealtime] PTT end: scheduling 400ms tail, then commit (healthy=%@)",
              webSocket != nil ? "true" : "false")
        pttTailTask = Task {
            // 400ms tail — captures trailing syllables (matches HeyClicky's tail window)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else {
                NSLog("[MiraRealtime] PTT end tail cancelled")
                return
            }
            await MainActor.run {
                NSLog("[MiraRealtime] commitAudioAndRequestResponse")
                self.emit(["type": "input_audio_buffer.commit"])
                self.emit(["type": "response.create"])
            }
        }
    }

    // MARK: - WebSocket lifecycle

    private func openSocket() {
        let model = "gpt-realtime-2"
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else { return }
        var req = URLRequest(url: url)
        req.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")

        NSLog("[MiraRealtime] WebSocket session opened model=%@", model)
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
                case .failure(let err):
                    NSLog("[MiraRealtime] receive failed: %@", err.localizedDescription)
                    guard self.shouldReconnect else { break }
                    if case .error    = self.state { break }
                    if case .connecting = self.state { break }
                    self.scheduleReconnect()
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

        // ── Step 1: server created session — send full config + set up playback ──
        case "session.created":
            guard shouldReconnect else { teardown(); return }
            configureSession()
            setupPlayback()

        // ── Step 2: config accepted — start mic, signal ready ────────────────────
        case "session.updated":
            guard shouldReconnect else { teardown(); return }
            retryCount = 0
            if !captureEngine.isRunning { startCapture() }
            if isAlwaysOn {
                NSLog("[MiraRealtime] always-on listening active")
            }
            state = .recording

        // ── Server VAD: user speech detected ─────────────────────────────────────
        case "input_audio_buffer.speech_started":
            NSLog("[MiraRealtime] always-on speech_start turn")
            if case .speaking = state {
                // Barge-in: stop playback and cancel in-flight response
                playerNode.stop()
                playerNode.reset()
                playerNode.play()
                emit(["type": "response.cancel"])
                NSLog("[MiraRealtime] interruptCurrentResponse")
            }
            userDraft = ""
            state     = .recording
            refreshContextInstructions()

        // ── Server VAD: user stopped speaking — server will auto-commit ──────────
        case "input_audio_buffer.speech_stopped":
            NSLog("[MiraRealtime] always-on speech_stopped — server committing")

        // ── User transcript (requires input_audio_transcription in session config) ─
        case "conversation.item.input_audio_transcription.completed":
            let text = event["transcript"] as? String ?? ""
            if !text.isEmpty {
                userDraft = text
                onUserMessage?(text)
                // Fire Computer Use element detection in parallel with AI response.
                // If a UI element is identified, PointToService animates to it.
                triggerElementDetection(for: text)
            }

        // ── Response lifecycle ────────────────────────────────────────────────────
        case "response.created":
            aiTranscript = ""
            aiDraft      = ""
            state        = .thinking

        case "response.output_audio.delta":
            if let delta = event["delta"] as? String {
                enqueueAudio(delta)
                if case .thinking = state {
                    state = .speaking
                    // Clear mic audio accumulated during thinking — prevents
                    // any buffered sound from triggering VAD on the next turn.
                    emit(["type": "input_audio_buffer.clear"])
                }
            }

        case "response.output_audio.done":
            // Schedule a sentinel buffer so we know exactly when playback drains
            if let sentinel = AVAudioPCMBuffer(pcmFormat: playFmt, frameCapacity: 1) {
                sentinel.frameLength = 1
                sentinel.floatChannelData?[0][0] = 0.0
                playerNode.scheduleBuffer(sentinel) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, case .speaking = self.state else { return }
                        NSLog("[MiraRealtime] player drained")
                        // Suppress VAD for 800ms after playback ends — prevents speaker
                        // audio from echoing back through mic and triggering a new turn.
                        self.suppressMicUntil = Date().addingTimeInterval(0.8)
                        self.state   = .recording
                        self.aiDraft = ""
                    }
                }
            }

        case "response.output_audio_transcript.delta":
            let delta = event["delta"] as? String ?? ""
            aiTranscript += delta
            aiDraft = Self.stripPointTag(from: aiTranscript)

        case "response.output_audio_transcript.done":
            let (cleanText, pt) = Self.extractPointTag(from: aiTranscript)
            if !cleanText.isEmpty { onAIMessage?(cleanText) }
            if let pt { PointToService.shared.point(toNormalized: pt) }

        // ── Tool call assembly ────────────────────────────────────────────────────
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
            toolStatus = Self.toolLabel(for: name, argsJSON: args)
            Task { await self.runTool(callId: id, name: name, argsJSON: args) }
            pendingCallId = ""; pendingToolName = ""; pendingToolArgs = ""

        case "error":
            let errObj = event["error"] as? [String: Any]
            let code   = errObj?["code"]    as? String ?? "?"
            let msg    = errObj?["message"] as? String ?? "Unknown error"
            NSLog("[MiraRealtime] server error — code=%@ msg=%@", code, msg)
            state = .error(msg)

        default:
            break
        }
    }

    // MARK: - Element detection (Computer Use)

    // Fires a background Computer Use API call when the user speaks. If a UI element
    // is identified, PointToService animates a cursor to it — independent of the
    // AI voice response. Ported from farzaa/clicky CompanionManager (MIT).
    private func triggerElementDetection(for transcript: String) {
        Task {
            do {
                let screens = try await ScreenCaptureService.captureAllDisplaysAsJPEG()
                // Use the cursor screen, or the first screen as fallback.
                guard let primary = screens.first(where: { $0.isCursorScreen }) ?? screens.first else { return }

                let appKitPt = await ElementLocationDetector.shared.detectElementLocation(
                    screenshotData: primary.imageData,
                    userQuestion:   transcript,
                    displayFrame:   primary.displayFrame
                )
                guard let appKitPt else { return }

                let normalized = ElementLocationDetector.shared.normalizedPoint(
                    appKitPt,
                    displayFrame: primary.displayFrame
                )
                PointToService.shared.point(toNormalized: normalized)
            } catch {
                // Non-critical — element detection failing doesn't affect voice response.
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        emit(buildSessionUpdate(includeFullConfig: true))
    }

    /// Refreshes instructions only — called at the start of each user turn
    /// so context (screen, clipboard, focused app) is always current.
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
            // Modalities, voice, and audio format — required for speech-to-speech
            session["modalities"]            = ["text", "audio"]
            session["voice"]                 = MiraVoice.saved.rawValue
            session["input_audio_format"]    = "pcm16"
            session["output_audio_format"]   = "pcm16"

            // Whisper transcription — enables conversation.item.input_audio_transcription.completed
            session["input_audio_transcription"] = ["model": "whisper-1"] as [String: Any]

            // Server VAD — the key that makes always-on work without any button press.
            // create_response: true means the server auto-commits and generates a response
            // whenever it detects the user has stopped speaking.
            session["turn_detection"] = [
                "type":               "server_vad",
                "threshold":          0.5,
                "prefix_padding_ms":  300,
                "silence_duration_ms": 700,
                "create_response":    true,
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

        let tgtFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate:  captureRate,
                                   channels:    1,
                                   interleaved: false)!
        inputConverter = AVAudioConverter(from: hwFmt, to: tgtFmt)

        node.installTap(onBus: 0, bufferSize: 4800, format: hwFmt) { [weak self] buf, _ in
            self?.encodeAndSend(buf)
        }
        captureEngine.prepare()
        do {
            try captureEngine.start()
            NSLog("[MiraRealtime] mic capture session running")
        } catch {
            NSLog("[MiraRealtime] mic capture start failed: %@", error.localizedDescription)
        }
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

        let count = Int(out.frameLength)
        var int16 = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            int16[i] = Int16(max(-32_768, min(32_767, Int32(floats[i] * 32_767))))
        }
        let base64 = Data(bytes: int16, count: count * 2).base64EncodedString()

        // RMS audio power — ported from farzaa/clicky BuddyDictationManager (MIT).
        var sumSq: Float = 0
        for i in 0..<count { sumSq += floats[i] * floats[i] }
        let rms = sqrt(sumSq / Float(max(1, count)))
        let boosted = min(max(rms * 10.2, 0), 1)

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Suppress mic while Mira is speaking (prevents speaker echo → VAD false positive)
            if case .speaking = self.state { return }
            // Post-response settle window — 800ms after playback drains
            guard Date() > self.suppressMicUntil else { return }
            self.emit(["type": "input_audio_buffer.append", "audio": base64])

            // Update power level with smoothing
            self.audioPowerLevel = max(CGFloat(boosted), self.audioPowerLevel * 0.72)
            let now = Date()
            if now.timeIntervalSince(self.lastPowerSampleDate) >= Self.powerSampleInterval {
                self.lastPowerSampleDate = now
                var hist = self.audioPowerHistory
                hist.append(max(CGFloat(boosted), 0.02))
                if hist.count > 44 { hist.removeFirst(hist.count - 44) }
                self.audioPowerHistory = hist
            }
        }
    }

    // MARK: - Audio playback (PCM16 from API → speakers)

    private func setupPlayback() {
        playEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playEngine.attach(playerNode)
        playEngine.connect(playerNode, to: playEngine.mainMixerNode, format: playFmt)
        try? playEngine.start()
        playerNode.play()
    }

    private func enqueueAudio(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let frames = data.count / 2
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
        let start  = Date()
        let output = await MiraToolService.execute(name: name, argsJSON: argsJSON)
        let ms     = Int(Date().timeIntervalSince(start) * 1000)
        await MainActor.run {
            ToolTraceStore.shared.record(toolName: name, argsJSON: argsJSON,
                                        result: output, durationMs: ms)
        }
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
        case "save_content":
            let dest = args["destination"] as? String ?? "notes"
            return dest == "files" ? "Saving file…" : "Saving to Notes…"
        case "open_application":
            let app = args["app_name"] as? String ?? "app"
            return "Opening \(app)…"
        case "get_calendar_events":  return "Checking your calendar…"
        case "control_music":
            let action = (args["action"] as? String ?? "controlling").capitalized
            return "\(action) music…"
        case "control_spotify":
            let action = args["action"] as? String ?? ""
            if action == "play_song", let song = args["song"] as? String {
                return "Playing \"\(song)\" on Spotify…"
            }
            return "\(action.capitalized.isEmpty ? "Controlling" : action.capitalized) Spotify…"
        case "search_web":
            let q = args["query"] as? String ?? "the web"
            return "Searching for \"\(q)\"…"
        case "run_shortcut":
            let s = args["shortcut_name"] as? String ?? "shortcut"
            return "Running \"\(s)\"…"
        case "run_apple_script":    return "Running script…"
        case "run_shell_command":
            let cmd = (args["command"] as? String ?? "").prefix(40)
            return "Running: \(cmd)…"
        case "set_volume":
            let lvl = args["level"] as? Int ?? 0
            return "Setting volume to \(lvl)%…"
        case "type_text":           return "Typing…"
        default:                    return "Working on it…"
        }
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
        reconnectTask?.cancel()
        teardown()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, shouldReconnect else { return }
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

    // MARK: - Point-tag parsing
    // The AI can embed <point x=N y=N> to direct attention to a screen element.

    private static let pointTagPattern =
        try! NSRegularExpression(pattern: #"<point\s+x=([\d.]+)\s+y=([\d.]+)>"#)

    private static func extractPointTag(from text: String) -> (String, CGPoint?) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pointTagPattern.firstMatch(in: text, range: range),
              let xRange = Range(match.range(at: 1), in: text),
              let yRange = Range(match.range(at: 2), in: text),
              let x = Double(text[xRange]),
              let y = Double(text[yRange]) else {
            return (text, nil)
        }
        let cleaned = pointTagPattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, CGPoint(x: x, y: y))
    }

    private static func stripPointTag(from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pointTagPattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - WebSocket emit

    private func emit(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}
