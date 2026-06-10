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

    private let wsURL     = URL(string: "wss://api.assemblyai.com/v3/realtime/ws?sample_rate=16000")!
    private let captureHz: Double = 16_000

    private var webSocketTask:  URLSessionWebSocketTask?
    private var urlSession:     URLSession?
    private var captureEngine   = AVAudioEngine()
    private var inputConverter: AVAudioConverter?
    private var accumulatedFinals: [String] = []

    // MARK: - Public API

    /// Throws if AVAudioEngine fails to start (e.g. mic permission denied or
    /// another engine already holds the hardware tap).
    func startStreaming() throws {
        guard !isStreaming else { return }

        partial            = ""
        sessionID          = ""
        accumulatedFinals  = []

        // Open WebSocket
        var request = URLRequest(url: wsURL)
        request.setValue(AppSecrets.assemblyAIKey, forHTTPHeaderField: "Authorization")
        urlSession    = URLSession(configuration: .default)
        let task      = urlSession!.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        receiveLoop()

        // Start mic capture
        try startCapture()
        isStreaming = true
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
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
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else { return }

        switch type {
        case "SessionBegins":
            sessionID = json["session_id"] as? String ?? ""

        case "PartialTranscript":
            let t = json["text"] as? String ?? ""
            if !t.isEmpty { partial = t }

        case "FinalTranscript":
            let t = json["text"] as? String ?? ""
            if !t.isEmpty {
                accumulatedFinals.append(t)
                partial = ""
            }

        case "SessionTerminated":
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil

        default:
            break
        }
    }

    private func sendTerminate() {
        let msg = URLSessionWebSocketTask.Message.string(#"{"terminate_session":true}"#)
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
        guard let conv = inputConverter else { return }
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
