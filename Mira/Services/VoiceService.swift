import Speech
import AVFoundation

@MainActor
class VoiceService: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var liveTranscript = ""

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    func requestPermissions() async {
        _ = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume(returning: ()) }
        }
    }

    func startListening() throws {
        guard !engine.isRunning else { return }

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        engine.prepare()
        try engine.start()
        isListening = true

        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            if let text = result?.bestTranscription.formattedString {
                Task { @MainActor [weak self] in self?.liveTranscript = text }
            }
        }
    }

    func stopListening() -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        isListening = false
        let final = liveTranscript
        liveTranscript = ""
        return final
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utt = AVSpeechUtterance(string: text)
        utt.rate = 0.52
        utt.pitchMultiplier = 1.05
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utt)
    }
}
