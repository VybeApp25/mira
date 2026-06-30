@preconcurrency import AVFoundation
import Foundation

// MARK: - LiveTranscriptionStream
//
// One AssemblyAI v3 realtime streaming session, decoupled from audio capture.
// Feed it PCM via `push(_:)` from ANY source (microphone, ScreenCaptureKit system
// audio); partial/final transcripts arrive on the main queue via callbacks. The
// call assistant runs two of these at once — one for the mic (the user) and one
// for system audio (the caller) — which is how speaker separation is achieved
// without ML diarization. See [[mira-meeting-assistant-spec]].
//
// Mirrors the working socket contract in AssemblyAIStreamingService (16 kHz mono
// PCM16, "partial_transcript"/"final_transcript" frames), generalized so the
// audio source is whatever calls `push`.

final class LiveTranscriptionStream: @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var onFinal:   ((String) -> Void)?
    var label = ""   // "me" / "caller" — for diagnostics only

    private var didLogNotReady   = false
    private var didLogConvertNil = false
    private var didLogFirstSend  = false

    private let wsURL    = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
    private let targetHz: Double = 16_000
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession:    URLSession?
    private var sessionReady = false
    private var running      = false
    private var converter:            AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    // MARK: Lifecycle

    func start() async {
        markRunning()

        // v3 (Universal-Streaming) takes config as QUERY PARAMS, not a config
        // frame, and authenticates via a `token` query param (proxy) or the
        // Authorization header (direct). Sending a v2-style config frame here is
        // why nothing transcribed before.
        var comps = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "sample_rate",  value: "16000"),
            URLQueryItem(name: "encoding",     value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
        ]

        var request: URLRequest
        if MiraBackend.useProxy {
            guard let token = await mintStreamingToken() else { stop(); return }
            items.append(URLQueryItem(name: "token", value: token))
            comps.queryItems = items
            request = URLRequest(url: comps.url ?? wsURL)
        } else {
            comps.queryItems = items
            request = URLRequest(url: comps.url ?? wsURL)
            request.setValue(AppSecrets.assemblyAIKey, forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default)
        let task    = session.webSocketTask(with: request)
        storeConnection(session: session, task: task)
        task.resume()
        receiveLoop()
    }

    // Synchronous lock helpers — keeps NSLock off the async `start()` path
    // (calling lock()/unlock() directly in an async context is a Swift 6 error).
    private func markRunning() { lock.lock(); running = true; lock.unlock() }
    private func storeConnection(session: URLSession, task: URLSessionWebSocketTask) {
        lock.lock(); urlSession = session; webSocketTask = task; lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false; sessionReady = false
        let task = webSocketTask; webSocketTask = nil
        lock.unlock()
        task?.send(.string(#"{"type":"Terminate"}"#)) { _ in }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Audio in (called on the capture thread)

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let ready = sessionReady
        let task  = webSocketTask
        lock.unlock()
        guard ready else {
            if !didLogNotReady { didLogNotReady = true; callDebugLog("[\(label)] push before socket ready") }
            return
        }
        guard let task else { return }
        guard let data = convert(buffer), !data.isEmpty else {
            if !didLogConvertNil {
                didLogConvertNil = true
                callDebugLog("[\(label)] convert produced no data (inCh=\(buffer.format.channelCount) inSR=\(buffer.format.sampleRate))")
            }
            return
        }
        if !didLogFirstSend { didLogFirstSend = true; callDebugLog("[\(label)] first audio send \(data.count) bytes") }
        task.send(.data(data)) { _ in }
    }

    /// Resample/convert an arbitrary input buffer to 16 kHz mono → PCM16 bytes.
    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inFmt = buffer.format
        lock.lock()
        if converter == nil || converterInputFormat != inFmt {
            converter = AVAudioConverter(from: inFmt, to: targetFormat)
            converterInputFormat = inFmt
        }
        let conv = converter
        lock.unlock()
        guard let conv else { return nil }

        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * targetHz / inFmt.sampleRate)
        guard outFrames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }

        var err: NSError?
        var consumed = false
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let floats = out.floatChannelData?[0] else { return nil }

        let count = Int(out.frameLength)
        guard count > 0 else { return nil }
        var int16 = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            int16[i] = Int16(max(-32_768, min(32_767, Int32(floats[i] * 32_767))))
        }
        return Data(bytes: int16, count: count * 2)
    }

    // MARK: WebSocket receive

    private func receiveLoop() {
        lock.lock(); let task = webSocketTask; let run = running; lock.unlock()
        guard run, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure:
                self.lock.lock(); self.running = false; self.sessionReady = false; self.lock.unlock()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "Begin", "session_begins":
            lock.lock(); sessionReady = true; lock.unlock()
            callDebugLog("[\(label)] socket ready (\(type))")

        case "Turn":
            // v3: each Turn carries the running transcript; end_of_turn marks it
            // final. format_turns=true gives a punctuated final pass.
            if let t = json["transcript"] as? String, !t.isEmpty {
                let endOfTurn = (json["end_of_turn"] as? Bool) ?? false
                let cb = endOfTurn ? onFinal : onPartial
                DispatchQueue.main.async { cb?(t) }
            }

        // v2 fallbacks (in case the endpoint ever speaks the old dialect).
        case "partial_transcript":
            if let t = json["transcript"] as? String, !t.isEmpty {
                let cb = onPartial; DispatchQueue.main.async { cb?(t) }
            }
        case "final_transcript":
            if let t = json["transcript"] as? String, !t.isEmpty {
                let cb = onFinal; DispatchQueue.main.async { cb?(t) }
            }

        default:
            break
        }
    }

    // MARK: Token (proxy mode mints a short-lived AssemblyAI token)

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
}
