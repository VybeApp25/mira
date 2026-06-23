@preconcurrency import AVFoundation
import Foundation

// AssemblyAI Universal-2 real-time streaming transcription.
// Mirrors the audio pipeline from RealtimeVoiceService but targets 16kHz PCM16
// and sends raw binary WebSocket frames instead of base64 JSON.
//
// Usage:
//   try AssemblyAIStreamingService.shared.startStreaming()
//   // observe .partial for live updates, .fullTranscript for the final result
//   AssemblyAIStreamingService.shared.stopStreaming()
//
// Mutually exclusive with RealtimeVoiceService always-on: if OpenAI Realtime
// is active, it holds the hardware input tap. Start this only when Realtime is idle.

@MainActor
final class AssemblyAIStreamingService: ObservableObject {
    static let shared = AssemblyAIStreamingService()
    private init() {}

    // MARK: - Published

    @Published private(set) var isStreaming = false
    @Published private(set) var partial:    String = ""
    @Published private(set) var sessionID:  String = ""

    // Accumulated final sentences joined with partial as suffix.
    var fullTranscript: String {
        var parts = accumulatedFinals
        if !partial.isEmpty { parts.append(partial) }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private

    private let wsURL     = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
    private let captureHz: Double = 16_000

    private var webSocketTask:  URLSessionWebSocketTask?
    private var urlSession:     URLSession?
    private var captureEngine   = AVAudioEngine()
    private var inputConverter: AVAudioConverter?
    private var accumulatedFinals: [String] = []
    // Gates audio sends until server confirms session is ready.
    private var sessionReady = false

    // MARK: - Public API

    /// Throws if AVAudioEngine fails to start (e.g. mic permission denied or
    /// another engine already holds the hardware tap).
    func startStreaming() throws {
        guard !isStreaming else { return }

        partial            = ""
        sessionID          = ""
        accumulatedFinals  = []
        sessionReady       = false

        // Start mic capture first (the throwing part). Frames are held until
        // sessionReady == true, so capturing before the socket opens is safe.
        try startCapture()
        isStreaming = true
        Task { [weak self] in await self?.openSocket() }
    }

    /// Opens the streaming WebSocket. Proxy mode mints a short-lived token and
    /// passes it as a query param (the raw key never leaves the server); direct
    /// mode authenticates with the embedded key as before.
    private func openSocket() async {
        var request: URLRequest
        if MiraBackend.useProxy {
            guard let token = await mintStreamingToken() else {
                NSLog("[AssemblyAI] no streaming token (proxy mode) — stopping")
                stopStreaming(); return
            }
            request = URLRequest(url: URL(string: "\(wsURL.absoluteString)?token=\(token)") ?? wsURL)
        } else {
            // Authorization is the raw key, no Bearer prefix.
            request = URLRequest(url: wsURL)
            request.setValue(AppSecrets.assemblyAIKey, forHTTPHeaderField: "Authorization")
        }

        urlSession    = URLSession(configuration: .default)
        let task      = urlSession!.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        // v3 requires a config message as the very first text frame.
        let cfg = #"{"sample_rate":16000,"encoding":"pcm_s16le"}"#
        task.send(.string(cfg)) { _ in }

        receiveLoop()
    }

    /// Mints an AssemblyAI streaming token via the JWT-authenticated edge function.
    private func mintStreamingToken() async -> String? {
        var req = URLRequest(url: MiraBackend.assemblyAITokenURL)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(AppSecrets.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.addValue("Bearer \(MiraBackend.supabaseBearer)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await MiraBackend.proxyData(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String, !token.isEmpty else { return nil }
            return token
        } catch { return nil }
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming   = false
        sessionReady  = false
        sendTerminate()
        stopCapture()
    }

    // MARK: - WebSocket receive

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                Task { @MainActor [weak self] in
                    self?.handle(message)
                    if self?.isStreaming == true { self?.receiveLoop() }
                }
            case .failure:
                Task { @MainActor [weak self] in
                    self?.isStreaming = false
                    self?.sessionReady = false
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session_begins":
            sessionID    = json["session_id"] as? String ?? ""
            sessionReady = true

        case "partial_transcript":
            let t = json["transcript"] as? String ?? ""
            if !t.isEmpty { partial = t }

        case "final_transcript":
            let t = json["transcript"] as? String ?? ""
            if !t.isEmpty {
                accumulatedFinals.append(t)
                partial = ""
            }

        case "session_terminated":
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil

        default:
            break
        }
    }

    private func sendTerminate() {
        let msg = URLSessionWebSocketTask.Message.string(#"{"type":"terminate"}"#)
        webSocketTask?.send(msg) { _ in }
    }

    // MARK: - Audio capture (mic → Float32 → PCM16 @ 16 kHz → binary frames)

    private func startCapture() throws {
        captureEngine   = AVAudioEngine()
        let node        = captureEngine.inputNode
        let hwFmt       = node.outputFormat(forBus: 0)

        let tgtFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate:   captureHz,
                                   channels:     1,
                                   interleaved:  false)!
        inputConverter = AVAudioConverter(from: hwFmt, to: tgtFmt)

        node.installTap(onBus: 0, bufferSize: 4096, format: hwFmt) { [weak self] buf, _ in
            self?.encodeAndSend(buf)
        }
        captureEngine.prepare()
        try captureEngine.start()
    }

    private func stopCapture() {
        if captureEngine.isRunning {
            captureEngine.inputNode.removeTap(onBus: 0)
            captureEngine.stop()
        }
        inputConverter = nil
    }

    // Called on the audio tap thread — no @MainActor state access here.
    private func encodeAndSend(_ buffer: AVAudioPCMBuffer) {
        guard sessionReady, let conv = inputConverter else { return }
        let outFrames = AVAudioFrameCount(
            Double(buffer.frameLength) * captureHz / buffer.format.sampleRate
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
        let audioData = Data(bytes: int16, count: count * 2)
        webSocketTask?.send(.data(audioData)) { _ in }
    }
}
