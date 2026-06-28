// RealtimeVoiceService.swift
// Mirrors HeyClicky's RealtimeVoiceController + RealtimeVoiceClient architecture.
//
// Two modes:
//   • Always-on  — connectAlwaysOn() on app launch; server_vad auto-commits turns.
//   • Push-to-talk — beginPushToTalk() / endPushToTalk() with 400ms tail commit.
//
// Pipeline: AVAudioEngine mic → PCM16 @ 24 kHz → base64 → WebSocket
//           WebSocket → PCM16 → Float32 → AVAudioPlayerNode → speakers
//
// Speaks the GA Realtime API (model gpt-realtime): session.update carries
// session.type="realtime" with nested audio.input/audio.output config, and
// the server emits response.output_audio.* events.

import Foundation
@preconcurrency import AVFoundation

// MARK: - Voice options

enum MiraVoice: String, CaseIterable, Identifiable {
    case alloy   = "alloy"
    case ash     = "ash"
    case ballad  = "ballad"
    case cedar   = "cedar"
    case coral   = "coral"
    case echo    = "echo"
    case marin   = "marin"
    case sage    = "sage"
    case shimmer = "shimmer"
    case verse   = "verse"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alloy:   return "Alloy — Neutral"
        case .ash:     return "Ash — Calm"
        case .ballad:  return "Ballad — Warm"
        case .cedar:   return "Cedar — Grounded"
        case .coral:   return "Coral — Bright"
        case .echo:    return "Echo — Crisp"
        case .marin:   return "Marin — Clear"
        case .sage:    return "Sage — Measured"
        case .shimmer: return "Shimmer — Soft"
        case .verse:   return "Verse — Expressive"
        }
    }

    /// The OpenAI TTS voice id sent to the speech endpoint (same as rawValue).
    var ttsVoice: String { rawValue }

    /// One shared line every voice speaks in the preview, so they're directly
    /// comparable. Kept in sync with PREVIEW_PHRASE in the openai-tts-proxy.
    static let previewPhrase = "Hi, I'm Mira, your AI companion. How can I help you today?"

    static var saved: MiraVoice {
        get { MiraVoice(rawValue: UserDefaults.standard.string(forKey: "mira_voice") ?? "alloy") ?? .alloy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mira_voice") }
    }

    /// Playback speed multiplier (0.5 – 2.0, default 1.0).
    static var savedSpeed: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "mira_voice_speed")
            return v == 0 ? 1.0 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "mira_voice_speed") }
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
    private let captureRate:    Double = 24_000   // GA Realtime audio/pcm is 24 kHz only

    // MARK: Private — Audio playback (API → speakers)

    private var playEngine    = AVAudioEngine()
    private var playerNode    = AVAudioPlayerNode()
    private var timePitchNode = AVAudioUnitTimePitch()
    private let playFmt       = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    // MARK: Private — Tool call assembly

    private var pendingCallId:   String = ""
    private var pendingToolName: String = ""
    private var pendingToolArgs: String = ""

    // MARK: Private — Transcript

    private var aiTranscript: String = ""

    // MARK: Private — Conversation continuity / screen context

    // True once persisted history has been replayed into this session —
    // session.updated fires on every per-turn instruction refresh, so the
    // injection must only happen once per socket.
    private var historyInjected = false

    /// Screen snapshot per voice turn (HeyClicky-style live screen awareness).
    /// Disable with `defaults write … mira_voice_screen_context -bool NO`.
    private var screenContextEnabled: Bool {
        UserDefaults.standard.object(forKey: "mira_voice_screen_context") == nil
            || UserDefaults.standard.bool(forKey: "mira_voice_screen_context")
    }

    /// Draw-on-screen spatial context coupled to PTT: hold the voice key, draw on
    /// screen, release → the annotated screenshot + coordinates ride the turn.
    /// Disable with `defaults write … mira_draw_context_enabled -bool NO`.
    private var drawContextEnabled: Bool {
        UserDefaults.standard.object(forKey: "mira_draw_context_enabled") == nil
            || UserDefaults.standard.bool(forKey: "mira_draw_context_enabled")
    }
    // True for the duration of a PTT hold that armed the draw overlay.
    private var pttDrawCoupled = false

    // MARK: Private — Session

    private var openAIKey       = ""
    private var shouldReconnect = false
    private var retryCount      = 0
    private var reconnectTask:  Task<Void, Never>?

    // MARK: Private — Voice usage reporting (free-tier throttle)

    // Wall-clock start of the current healthy session; on teardown the elapsed
    // seconds are POSTed to report-voice-usage so the server's daily seconds cap
    // accumulates real usage. See migration 20260628120000_voice_usage_quota.sql.
    private var sessionStartedAt: Date?

    // Result of an ephemeral-token mint — lets openSocket distinguish a daily
    // voice-cap rejection (429) from a generic failure, so the UI can show an
    // upgrade-friendly message instead of "sign in".
    private enum MintResult {
        case token(String)
        case quotaExceeded
        case failed
    }

    // MARK: Private — Always-on

    private var isAlwaysOn = false
    // Suppresses VAD for a settle period after the response audio finishes.
    // Prevents speaker audio echoing back through the mic from triggering a new turn.
    private var suppressMicUntil: Date = .distantPast

    // MARK: Private — PTT (mirrors HeyClicky's pushToTalkTailCommitTask)

    private var pttActive:        Bool               = false
    private var pttTailTask:      Task<Void, Never>?
    private var pttPeakPower:     Float              = 0  // peak RMS during current PTT hold
    // True after session.updated — gates the PTT commit so audio is never sent to an unready socket
    private var sessionHealthy:   Bool               = false
    // Keeps the WebSocket warm for 3 min after a PTT response so next PTT skips cold-start
    private var idleTeardownTask: Task<Void, Never>?
    // True while a background pre-warm session is open but mic is not yet started.
    // Mirrors HeyClicky's "agent keep-warm flag" — session is healthy, mic is off.
    private var isWarmStandby:    Bool               = false

    // MARK: - Public API

    /// Start always-on listening.
    func connectAlwaysOn() {
        guard !isAlwaysOn else { return }
        if webSocket != nil { teardown() }   // close any warm PTT session first
        isAlwaysOn       = true
        isAlwaysOnActive = true
        shouldReconnect  = true
        retryCount       = 0
        state            = .connecting
        NSLog("[MiraRealtime] always-on start")
        openSocket()
    }

    /// Pre-warm the Realtime WebSocket on app launch so the first PTT is instant.
    /// Opens the connection silently — mic is NOT started, state stays .idle.
    /// When PTT fires it finds a healthy session and begins recording immediately.
    /// Mirrors HeyClicky's "agent keep-warm flag" / prewarm-Agent-Mode-session pattern.
    func prewarm() {
        guard !isAlwaysOn, webSocket == nil, !isWarmStandby else { return }
        guard MiraBackend.useProxy || !AppSecrets.openAIKey.isEmpty else { return }
        NSLog("[MiraRealtime] pre-warming session")
        isWarmStandby   = true
        shouldReconnect = false   // warm standby doesn't auto-reconnect on drop
        retryCount      = 0
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
        pttTailTask?.cancel();      pttTailTask = nil
        idleTeardownTask?.cancel(); idleTeardownTask = nil
        pttActive = true

        // Voice-coupled drawing: arm the freehand overlay so the user can mark up the
        // screen while talking. The annotated capture is emitted at end-of-turn
        // (flushed in the PTT tail, just before commit). The begin-time snapshot below
        // still sends a clean baseline.
        // Voice-coupled draw is opt-in — only arm when user explicitly enabled it in Settings.
        // Default is off so ⌃⌥V (voice) and ⌃⌥D (draw) stay independent.
        pttDrawCoupled = false
        pttPeakPower   = 0

        if webSocket != nil && sessionHealthy {
            // Warm session (or warm standby) — mic was stopped; restart it and clear any stale buffer.
            isWarmStandby = false
            NSLog("[MiraRealtime] PTT begin: reusing healthy session")
            if !captureEngine.isRunning { startCapture() }
            emit(["type": "input_audio_buffer.clear"])
            // Inject history on the first real turn of a pre-warmed session.
            if !historyInjected {
                historyInjected = true
                injectConversationHistory()
            }
            sendScreenSnapshot()
            state = .recording
        } else if webSocket != nil {
            // Socket exists but not yet healthy — already in flight; health-poll will gate commit
            NSLog("[MiraRealtime] PTT begin: session opening, health poll will gate commit")
        } else {
            // Cold start — open a fresh session
            NSLog("[MiraRealtime] PTT begin: opening fresh session")
            shouldReconnect = true
            retryCount      = 0
            state           = .connecting
            openSocket()
        }
    }

    /// Called when PTT hotkey is released — 400ms tail, health poll, then manual commit.
    func endPushToTalk() {
        guard pttActive else { return }
        pttActive = false
        NSLog("[MiraRealtime] PTT end: scheduling 400ms tail (healthy=%@)",
              sessionHealthy ? "true" : "false")
        pttTailTask = Task {
            // 400ms tail — captures trailing syllables (matches HeyClicky's 400ms tail window)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else {
                NSLog("[MiraRealtime] PTT end tail cancelled")
                return
            }
            // Poll until session is healthy — mirrors HeyClicky's health-poll-before-commit.
            // Without this, the commit races with the WebSocket handshake and is silently dropped.
            let deadline = Date().addingTimeInterval(4.0)
            while true {
                let healthy = await MainActor.run { self.sessionHealthy }
                if healthy { break }
                if Date() > deadline {
                    NSLog("[MiraRealtime] PTT end: gave up waiting (health poll timeout)")
                    return
                }
                guard !Task.isCancelled else {
                    NSLog("[MiraRealtime] PTT end tail cancelled during health-poll")
                    return
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            // If the user drew on screen during this hold, capture + composite the
            // marks and emit the annotated image + coordinates BEFORE the response is
            // requested, so the model sees them as part of this turn.
            if await MainActor.run(body: { self.pttDrawCoupled }) {
                if let ctx = await ScreenDrawController.shared.commit() {
                    await MainActor.run { self.emitDrawnContext(ctx) }
                }
                await MainActor.run { self.pttDrawCoupled = false }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let hadSpeech = self.pttPeakPower > 0.01
                NSLog("[MiraRealtime] PTT end: session healthy — committing (peakPower=%.4f hadSpeech=%@)",
                      self.pttPeakPower, hadSpeech ? "YES" : "NO")
                self.emit(["type": "input_audio_buffer.commit"])
                if hadSpeech {
                    AudioCueService.shared.playTextSend()
                    self.emit(["type": "response.create"])
                } else {
                    // No speech detected — clear buffer, no response
                    self.emit(["type": "input_audio_buffer.clear"])
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - WebSocket lifecycle

    private func openSocket() {
        Task { await openSocketAsync() }
    }

    private func openSocketAsync() async {
        let model     = "gpt-realtime"
        // In proxy mode the ephemeral token is minted against the signed-in user's
        // Supabase JWT, which expires ~1h after sign-in. Renew it first so a stale
        // token (timer missed while asleep, etc.) self-heals instead of 401'ing the
        // mint — the most common cause of a session stuck on "Connecting".
        if MiraBackend.useProxy {
            await SupabaseService.shared.ensureFreshToken()
        }
        // Prefer the minted ephemeral token. Fall back to the embedded key ONLY in
        // direct mode; in proxy mode a mint failure must NOT leak the raw key —
        // refuse to connect instead.
        let authToken: String
        switch await fetchEphemeralToken() {
        case .token(let t):
            authToken = t
        case .quotaExceeded:
            // Daily voice cap hit — stop the reconnect/always-on loop and show an
            // upgrade-friendly message rather than retrying (which would just 429
            // again and burn the cap-check on the server).
            NSLog("[MiraRealtime] mint blocked — daily voice quota exceeded")
            shouldReconnect  = false
            isAlwaysOn       = false
            isAlwaysOnActive = false
            reconnectTask?.cancel(); reconnectTask = nil
            teardown()
            state = .error("Daily voice limit reached — upgrade for more.")
            return
        case .failed:
            guard !MiraBackend.useProxy, !AppSecrets.openAIKey.isEmpty else {
                // Don't leave the UI hanging on "Connecting" forever: the mint failed
                // (no valid signed-in session). Stop any reconnect/always-on loop and
                // surface an actionable error.
                NSLog("[MiraRealtime] mint failed (proxy mode) — surfacing sign-in error")
                shouldReconnect  = false
                isAlwaysOn       = false
                isAlwaysOnActive = false
                reconnectTask?.cancel(); reconnectTask = nil
                teardown()
                state = .error("Sign in to use voice")
                return
            }
            authToken = AppSecrets.openAIKey
        }

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else { return }
        var req = URLRequest(url: url)
        req.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        NSLog("[MiraRealtime] WebSocket session opened model=%@", model)
        urlSession = URLSession(configuration: .default)
        webSocket  = urlSession?.webSocketTask(with: req)
        webSocket?.resume()
        pump()
    }

    // Mints a short-lived ephemeral token via the Supabase edge function so the
    // raw OpenAI key never travels over the WebSocket connection (matches HeyClicky's
    // /agent/session-token backend pattern). Falls back to raw key on any failure.
    private func fetchEphemeralToken() async -> MintResult {
        let endpoint = "\(AppSecrets.supabaseURL)/functions/v1/mint-realtime-token"
        guard let url = URL(string: endpoint) else { return .failed }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        // verify_jwt requires a Bearer token — without it the function 401s
        // and every session silently falls back to the raw OpenAI key.
        req.addValue("Bearer \(MiraBackend.supabaseBearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["voice": MiraVoice.saved.rawValue]
        )

        do {
            let (data, resp) = try await MiraBackend.proxyData(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 429 = daily voice cap reached (server-authoritative). Distinct from a
            // generic failure so the UI can prompt an upgrade rather than sign-in.
            if status == 429 {
                NSLog("[MiraRealtime] mint-token: daily voice quota exceeded (429)")
                return .quotaExceeded
            }
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String, !token.isEmpty else {
                NSLog("[MiraRealtime] mint-token: bad response (status %d), using fallback", status)
                return .failed
            }
            NSLog("[MiraRealtime] ephemeral token minted OK")
            return .token(token)
        } catch {
            NSLog("[MiraRealtime] mint-token failed: %@, using fallback", error.localizedDescription)
            return .failed
        }
    }

    /// Reports the duration of a realtime session to the backend so the daily
    /// seconds cap accumulates (the soft half of the free-tier voice throttle).
    /// Best-effort, fire-and-forget — failure never affects the user. Proxy mode
    /// + signed-in only (direct mode has no server to meter against).
    private func reportVoiceUsage(seconds: Int) {
        guard seconds > 0, MiraBackend.useProxy, SupabaseService.shared.isSignedIn else { return }
        let endpoint = "\(AppSecrets.supabaseURL)/functions/v1/report-voice-usage"
        guard let url = URL(string: endpoint) else { return }
        Task.detached {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
            req.addValue("Bearer \(MiraBackend.supabaseBearer)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["seconds": seconds])
            _ = try? await MiraBackend.proxyData(for: req)
        }
    }

    private func pump() {
        guard let socket = webSocket else { return }
        socket.receive { [weak self, weak socket] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore callbacks from sockets that teardown()/reconnect already
                // replaced — only the live socket may drive state or reconnection.
                guard let socket, socket === self.webSocket else { return }
                switch result {
                case .success(let msg):
                    self.dispatch(msg)
                    self.pump()
                case .failure(let err):
                    NSLog("[MiraRealtime] receive failed: %@", err.localizedDescription)
                    guard self.shouldReconnect else { break }
                    if case .error = self.state { break }
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
              let type = json["type"] as? String else {
            NSLog("[MiraRealtime] unparseable frame: %@", String(text.prefix(200)))
            return
        }
        // Audio/transcript deltas arrive many times per second — don't log those.
        if !type.hasSuffix(".delta") {
            NSLog("[MiraRealtime] ← %@", type)
        }
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
            guard shouldReconnect || isWarmStandby else { teardown(); return }
            retryCount     = 0
            sessionHealthy = true
            if sessionStartedAt == nil { sessionStartedAt = Date() }
            if isWarmStandby {
                // Warm standby: session is healthy but mic stays off until PTT fires.
                // Don't inject history or change state — stay invisible until needed.
                NSLog("[MiraRealtime] warm standby ready")
                return
            }
            if !captureEngine.isRunning { startCapture() }
            if !historyInjected {
                historyInjected = true
                injectConversationHistory()
                // Cold-start turn (PTT cold open / first always-on turn) has no
                // speech_started yet — attach the screen for the first question.
                sendScreenSnapshot()
            }
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
                // A cancelled response never emits transcript.done, which is the
                // only place that arms the bubble's auto-fade — so fade it here or
                // the half-spoken caption is orphaned on screen.
                CursorBubbleService.shared.finishStreaming()
            }
            userDraft = ""
            state     = .recording
            refreshContextInstructions()
            sendScreenSnapshot()

        // ── Server VAD: user stopped speaking — server will auto-commit ──────────
        case "input_audio_buffer.speech_stopped":
            NSLog("[MiraRealtime] always-on speech_stopped — server committing")

        // ── User transcript (requires input_audio_transcription in session config) ─
        case "conversation.item.input_audio_transcription.completed":
            let text = event["transcript"] as? String ?? ""
            if !text.isEmpty && !Self.isPhantomTranscript(text) {
                userDraft = text
                ConversationStore.shared.save(role: "user", text: text)
                onUserMessage?(text)
                // Fire Computer Use element detection in parallel with AI response.
                // If a UI element is identified, PointToService animates to it.
                triggerElementDetection(for: text)
            } else if !text.isEmpty {
                // Whisper hallucinated on noise/silence (VAD fired on ambient sound).
                // Drop it silently and clear the buffer so the next turn starts clean.
                NSLog("[MiraRealtime] dropped phantom transcript: \(text)")
                emit(["type": "input_audio_buffer.clear"])
            }

        // ── Response lifecycle ────────────────────────────────────────────────────
        case "response.created":
            aiTranscript = ""
            aiDraft      = ""
            state        = .thinking
            // Live captions at the cursor while Mira speaks (HeyClicky parity)
            CursorBubbleService.shared.showStreaming()

        case "response.output_audio.delta":
            if let delta = event["delta"] as? String {
                enqueueAudio(delta)
                if case .thinking = state {
                    state = .speaking
                    AudioCueService.shared.playTextReceive()
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
                        if self.isAlwaysOn {
                            // Always-on: suppress VAD briefly then go back to listening.
                            self.suppressMicUntil = Date().addingTimeInterval(0.8)
                            self.state   = .recording
                            self.aiDraft = ""
                        } else {
                            // PTT mode: keep session warm for 30s so next PTT skips cold-start.
                            // Stop mic to prevent server_vad from auto-committing ambient audio.
                            NSLog("[MiraRealtime] PTT response complete — warm idle (30s window)")
                            self.stopMicCapture()
                            self.aiDraft = ""
                            self.state   = .idle
                            self.scheduleIdleTeardown()
                        }
                    }
                }
            }

        case "response.output_audio_transcript.delta":
            let delta = event["delta"] as? String ?? ""
            aiTranscript += delta
            aiDraft = Self.stripPointTag(from: aiTranscript)
            // Point tags only ever appear at the very end — keep them out of
            // the caption by never streaming past the first '<'.
            if !delta.contains("<"), !aiTranscript.contains("<point") {
                CursorBubbleService.shared.append(token: delta)
            }

        case "response.output_audio_transcript.done":
            let (cleanText, pt) = Self.extractPointTag(from: aiTranscript)
            if !cleanText.isEmpty {
                ConversationStore.shared.save(role: "mira", text: cleanText)
                onAIMessage?(cleanText)
            }
            if let pt { PointToService.shared.point(toNormalized: pt) }
            CursorBubbleService.shared.finishStreaming()

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
            // Benign races — cancelling a response that already finished, or
            // committing an empty buffer — don't invalidate the session.
            // Going to .error here would kill always-on listening for nothing.
            let benign = code == "response_cancel_not_active"
                      || code == "input_audio_buffer_commit_empty"
                      || msg.contains("no active response")
                      || msg.contains("buffer too small")
            if !benign {
                state = .error(msg)
                // Error aborts the response before transcript.done — clear any
                // partial caption so it doesn't stick to the cursor.
                CursorBubbleService.shared.hide()
            }

        default:
            break
        }
    }

    // MARK: - Element detection (Computer Use)

    // Fires a background Computer Use API call when the user speaks. If a UI element
    // is identified, PointToService animates a cursor to it — independent of the
    // AI voice response. Ported from farzaa/clicky CompanionManager (MIT).
    private func triggerElementDetection(for transcript: String) {
        let guidanceId = UUID()
        GuidanceEvidenceService.shared.recordRequested(id: guidanceId, transcriptChars: transcript.count)
        Task {
            do {
                let screens = try await ScreenCaptureService.captureAllDisplaysAsJPEG()
                // Use the cursor screen, or the first screen as fallback.
                guard let primary = screens.first(where: { $0.isCursorScreen }) ?? screens.first else {
                    GuidanceEvidenceService.shared.recordOutcome(
                        id: guidanceId, detection: .failed(reason: "no_display"),
                        normalized: nil, display: "")
                    return
                }

                let display = "\(primary.displayWidthInPoints)x\(primary.displayHeightInPoints)"

                // Route through the grounding gate (Teaching System M1): never draw
                // on a target we can't ground. The gate decides annotate / ask / nothing.
                let outcome = await GroundingService.shared.ground(
                    question:       transcript,
                    screenshotData: primary.imageData,
                    displayFrame:   primary.displayFrame
                )

                switch outcome {
                case .grounded(let normalized, let appKit, _, _):
                    GuidanceEvidenceService.shared.recordOutcome(
                        id: guidanceId, detection: .located(appKit), normalized: normalized, display: display)
                    switch gateDecision(for: outcome) {
                    case .annotate:
                        PointToService.shared.point(toNormalized: normalized)
                        AnnotationCanvasService.shared.show(
                            [.ring(around: normalized, radiusPt: 26)], autoClearAfter: 4)
                    case .ask, .nothingToShow:
                        // Below the confidence gate — don't draw on a spot we're unsure of.
                        break
                    }

                case .noElement:
                    GuidanceEvidenceService.shared.recordOutcome(
                        id: guidanceId, detection: .noElement, normalized: nil, display: display)

                case .uncertain(let reason):
                    GuidanceEvidenceService.shared.recordOutcome(
                        id: guidanceId, detection: .failed(reason: reason), normalized: nil, display: display)
                }
            } catch {
                // Non-critical — element detection failing doesn't affect voice response.
                GuidanceEvidenceService.shared.recordOutcome(
                    id: guidanceId, detection: .failed(reason: "capture"),
                    normalized: nil, display: "")
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

    // MARK: - One-off task announcement (autonomy)

    /// True when there's a live, healthy realtime session that can speak a one-off
    /// line right now — and Mira isn't already mid-response (injecting then would
    /// collide with the active response / interrupt a conversational turn).
    var canSpeakNow: Bool {
        guard webSocket != nil, sessionHealthy else { return false }
        switch state {
        case .thinking, .speaking, .connecting: return false
        default:                                return true
        }
    }

    /// Speak a one-off status line through the live session in the user's selected
    /// Mira voice (MiraVoice.saved), and silently seed `context` into the
    /// conversation so a follow-up ("what did you do?") can be answered with the
    /// full detail. Returns false if there's no healthy session — the caller then
    /// falls back to local TTS. Used by TaskAnnouncer. See
    /// project_mira_autonomy_direction.
    @discardableResult
    func speakAnnouncement(brief: String, context: String?) -> Bool {
        guard canSpeakNow else { return false }

        // Seed the full detail as a prior assistant turn so the model can elaborate
        // if asked, without speaking it now.
        if let context, !context.isEmpty {
            emit([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "assistant",
                    "content": [[
                        "type": "output_text",
                        "text": "[autonomous task just completed] \(context)"
                    ]] as [[String: Any]]
                ] as [String: Any]
            ])
        }

        // Speak the brief in the session voice. Per-response instructions keep it
        // short and stop it from drifting into a full conversational turn.
        emit([
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "instructions": "Tell the user, briefly and naturally in one sentence, "
                    + "what you just finished. Say it as: \(brief). Do not add follow-up questions."
            ] as [String: Any]
        ])
        return true
    }

    // MARK: - Conversation continuity

    /// Replays recent persisted history into the fresh Realtime session so
    /// "what did we just talk about?" works across PTT/always-on sessions.
    private func injectConversationHistory() {
        let entries = ConversationStore.shared.entries.suffix(10)
        guard !entries.isEmpty else { return }
        for e in entries {
            let isUser = e.role == "user"
            emit([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": isUser ? "user" : "assistant",
                    "content": [[
                        "type": isUser ? "input_text" : "output_text",
                        "text": String(e.text.prefix(600))
                    ]] as [[String: Any]]
                ] as [String: Any]
            ])
        }
        NSLog("[MiraRealtime] injected %d history items", entries.count)
    }

    // MARK: - Live screen context

    /// Captures the cursor's screen and attaches it to the current turn as an
    /// input_image item — gives the model HeyClicky-style live screen awareness.
    private func sendScreenSnapshot() {
        guard screenContextEnabled else { return }
        // If the user pre-marked the screen (⌃⌥D, then talk), send the annotated
        // capture + coordinates instead of a fresh clean shot.
        if let ctx = PendingDrawnContextService.shared.pop() {
            emitDrawnContext(ctx)
            return
        }
        Task { [weak self] in
            do {
                let screens = try await ScreenCaptureService.captureAllDisplaysAsJPEG()
                guard let primary = screens.first(where: { $0.isCursorScreen }) ?? screens.first
                else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.sessionHealthy else { return }
                    self.emit([
                        "type": "conversation.item.create",
                        "item": [
                            "type": "message",
                            "role": "user",
                            "content": [[
                                "type": "input_image",
                                "image_url": "data:image/jpeg;base64,\(primary.imageData.base64EncodedString())"
                            ]] as [[String: Any]]
                        ] as [String: Any]
                    ])
                    NSLog("[MiraRealtime] screen snapshot attached (%d KB)",
                          primary.imageData.count / 1024)
                }
            } catch {
                // Screen context is best-effort — the voice turn proceeds without it.
            }
        }
    }

    /// Emit a user-drawn spatial-context item: the annotated screenshot plus a text
    /// part describing the marked region (normalized coords). Same `conversation.item.create`
    /// shape as sendScreenSnapshot, just with the marks burned in + a coordinate hint.
    private func emitDrawnContext(_ ctx: DrawnContext) {
        guard sessionHealthy, let jpeg = ctx.annotatedJPEGData() else { return }
        emit([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_image",
                     "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                    ["type": "input_text", "text": ctx.coordinateHint]
                ] as [[String: Any]]
            ] as [String: Any]
        ])
        NSLog("[MiraRealtime] drawn spatial context attached (%d KB)", jpeg.count / 1024)
    }

    private func buildSessionUpdate(includeFullConfig: Bool) -> [String: Any] {
        let contextBlock = ContextService.shared.buildPromptBlock()
        let instructions = MiraPrompts.realtimeSystem + "\n\n" + contextBlock

        // GA Realtime requires session.type on every session.update —
        // omitting it returns missing_required_parameter and the update is dropped.
        var session: [String: Any] = [
            "type":         "realtime",
            "instructions": instructions
        ]

        if includeFullConfig {
            // Server VAD belongs ONLY to always-on listening. In push-to-talk the
            // user's key hold defines the turn, so VAD must be OFF — otherwise the
            // server auto-commits on silence and on ambient noise, racing the
            // manual commit-on-release (broken hold/release) and feeding the model
            // garbage audio it answers in random languages. null disables it.
            let turnDetection: Any = isAlwaysOn
                ? ([
                    "type":                "server_vad",
                    // 0.65 (was 0.5): higher bar so ambient room noise / fans / typing
                    // don't cross the speech threshold and auto-commit a phantom turn.
                    // Lower toward 0.55 only if it starts missing soft-spoken starts.
                    // NSDecimalNumber, not a Double literal: JSONSerialization renders
                    // 0.65 as a Double as "0.65000000000000002" (17 places), which the
                    // Realtime API rejects ("threshold: max decimal places exceeded").
                    // NSDecimalNumber serializes as exactly "0.65".
                    "threshold":           NSDecimalNumber(string: "0.65"),
                    "prefix_padding_ms":   300,
                    // Snappier continuous turn-taking — commit ~400ms after silence
                    // so replies come fast (HeyClicky-style). Bump back toward 500 if
                    // it clips trailing words.
                    "silence_duration_ms": 400
                  ] as [String: Any])
                : NSNull()

            session["output_modalities"] = ["audio"]
            session["audio"] = [
                "input": [
                    "format":        ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                    // Strip background noise before it reaches VAD + transcription.
                    // near_field = mic close to the user (built-in mic / headset);
                    // this is the biggest lever against "heard words when silent".
                    "noise_reduction": ["type": "near_field"] as [String: Any],
                    // Pin transcription to English so short/ambiguous audio isn't
                    // mis-detected into another language (used for element detection).
                    "transcription": ["model": "whisper-1", "language": "en"] as [String: Any],
                    "turn_detection": turnDetection
                ] as [String: Any],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                    "voice":  MiraVoice.saved.rawValue
                ] as [String: Any]
            ] as [String: Any]
            session["tools"]       = MiraToolService.definitions
            session["tool_choice"] = "auto"
        }

        return ["type": "session.update", "session": session]
    }

    /// Whisper reliably hallucinates a small set of stock phrases when handed
    /// near-silence or non-speech noise (the audio a too-eager VAD commits when
    /// no one is actually talking). These are almost never real commands, so we
    /// drop them rather than feed the model a turn it has to answer. Short, real
    /// utterances ("yes", "no", "stop", "next") are deliberately NOT in this set.
    private static let phantomTranscripts: Set<String> = [
        "you", "thank you", "thanks", "thank you.", "thanks for watching",
        "thanks for watching!", "thank you for watching", "bye", "bye.",
        "okay", "ok", ".", "..", "...", "uh", "um", "hmm", "mm", "mhm",
        "you're", "so", "yeah", "right", "i", "the", "a"
    ]

    static func isPhantomTranscript(_ raw: String) -> Bool {
        // Normalize: lowercase, strip surrounding whitespace and trailing
        // punctuation so "You." and "you" collapse to the same key.
        let normalized = raw
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,!?…\"'-♪"))
        if normalized.isEmpty { return true }
        return phantomTranscripts.contains(normalized)
    }

    // MARK: - Audio capture (mic → PCM16 → WebSocket)

    private func startCapture() {
        pauseMusicPlayers()
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
        if pttActive { pttPeakPower = max(pttPeakPower, rms) }
        let boosted = min(max(rms * 10.2, 0), 1)

        Task { @MainActor [weak self] in
            guard let self else { return }
            // While Mira is speaking, keep streaming the mic ONLY on external output
            // (headphones/AirPods) so server-VAD can detect a barge-in and the
            // speech_started handler can interrupt her. On the built-in speaker this
            // would echo Mira's own voice back and self-interrupt, so we stay silent
            // and let her finish — barge-in is headphones-only by design.
            if case .speaking = self.state, !AudioOutputRoute.isExternalOutput { return }
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
        playEngine    = AVAudioEngine()
        playerNode    = AVAudioPlayerNode()
        timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.rate = Float(MiraVoice.savedSpeed)
        playEngine.attach(playerNode)
        playEngine.attach(timePitchNode)
        playEngine.connect(playerNode,    to: timePitchNode,          format: playFmt)
        playEngine.connect(timePitchNode, to: playEngine.mainMixerNode, format: playFmt)
        try? playEngine.start()
        playerNode.play()
    }

    /// Update playback speed live (0.5 – 2.0). Persists the preference.
    func setSpeed(_ speed: Double) {
        MiraVoice.savedSpeed = speed
        timePitchNode.rate   = Float(speed)
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
            if action == "play_song" {
                let song   = (args["song"]   as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let track  = (args["track"]  as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = (args["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let label  = !song.isEmpty ? song
                           : [track, artist].filter { !$0.isEmpty }.joined(separator: " by ")
                if !label.isEmpty { return "Playing \"\(label)\" on Spotify…" }
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

    private func stopMicCapture() {
        guard captureEngine.isRunning else { return }
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        inputConverter = nil
        resumeMusicPlayers()
    }

    // Pause Spotify and Music during mic capture so they don't bleed into the recording.
    // Resume is best-effort — only apps that were ACTUALLY playing when we paused are
    // resumed. Tracking which apps we paused (instead of a single bool) is what keeps
    // toggling voice from spuriously *starting* music that was stopped/paused: the old
    // code set its flag whenever the AppleScript merely ran (the result descriptor is
    // non-nil even when nothing was playing), so exiting voice sent `play` unconditionally.
    private var pausedMusicApps: [String] = []

    private func pauseMusicPlayers() {
        pausedMusicApps = []
        for app in ["Spotify", "Music"] {
            // Returns "paused" ONLY when the app was running and actively playing.
            let src = """
            tell application "\(app)"
                if it is running then
                    if player state is playing then
                        pause
                        return "paused"
                    end if
                end if
            end tell
            return "no"
            """
            var err: NSDictionary?
            let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
            if err == nil, result?.stringValue == "paused" {
                pausedMusicApps.append(app)
            }
        }
    }

    private func resumeMusicPlayers() {
        let apps = pausedMusicApps
        pausedMusicApps = []
        for app in apps {
            let src = "tell application \"\(app)\" to if it is running then play"
            NSAppleScript(source: src)?.executeAndReturnError(nil)
        }
    }

    private func scheduleIdleTeardown() {
        idleTeardownTask?.cancel()
        idleTeardownTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000_000)  // 3 min warm window
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.isAlwaysOn else { return }
                NSLog("[MiraRealtime] idle teardown — closing warm session, will re-warm")
                self.stop()
                // Re-warm immediately so the next PTT is still instant
                self.prewarm()
            }
        }
    }

    private func teardown() {
        // Report this session's duration to the daily seconds cap before resetting.
        // Reconnects tear down + reopen, so each live segment is reported and the
        // server sums them — that's correct.
        if let started = sessionStartedAt {
            let elapsed = Int(Date().timeIntervalSince(started).rounded())
            reportVoiceUsage(seconds: elapsed)
            sessionStartedAt = nil
        }
        sessionHealthy  = false
        historyInjected = false
        isWarmStandby   = false
        idleTeardownTask?.cancel()
        idleTeardownTask = nil

        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket  = nil
        urlSession = nil

        stopMicCapture()

        playerNode.stop()
        if playEngine.isRunning { playEngine.stop() }

        // If the session dies mid-reply, transcript.done never fires — force the
        // cursor caption off so it isn't orphaned after the socket closes.
        CursorBubbleService.shared.hide()
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
              let str  = String(data: data, encoding: .utf8) else {
            // A non-JSON-serializable value (Date, enum, …) anywhere in the
            // payload throws — swallowing it would silently kill the handshake.
            NSLog("[MiraRealtime] emit DROPPED — payload not JSON-serializable (type=%@)",
                  dict["type"] as? String ?? "?")
            return
        }
        webSocket?.send(.string(str)) { error in
            if let error {
                NSLog("[MiraRealtime] send failed: %@", error.localizedDescription)
            }
        }
    }
}
