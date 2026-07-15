import AppKit
import Combine

// MARK: - DictationAnywhereService
//
// Hold-to-talk dictation that lands text in the focused field of ANY app —
// Mira's answer to (and improvement on) HeyClicky's "dictate anywhere" hero
// demo. This is distinct from the two existing dictation surfaces:
//
//   • IslandChatView.toggleDictate → fills Mira's OWN chat input box.
//   • RealtimeVoiceService PTT      → a full voice ASSISTANT turn.
//
// Dictate-anywhere is pure transcription-to-caret: press ⌃⌥S, speak, release,
// and the words appear where you were typing — Notes, Slack, a code editor, a
// browser field. Everything is already in the app; this just wires the pieces:
//
//   AssemblyAIStreamingService (transcribe)  →  live HUD preview
//                                            →  AXActuationService.insertTextAtSystemFocus
//                                            →  pasteboard + ⌘V fallback (AX-poor apps)
//
// "And better" vs HeyClicky: the AX caret-insert path writes into the focused
// element WITHOUT touching the clipboard or synthesizing keystrokes — no clobbered
// pasteboard, no dropped characters — and only falls back to paste for apps that
// don't expose an accessible selection.
//
// Mic exclusivity: always-on Realtime would otherwise transcribe AND respond to
// the same speech (a full assistant turn firing off your dictation). We pause it
// for the duration and restore it on release. The "Hey Mira" wake word only fires
// on the literal trigger phrase and already self-pauses during sessions, so it
// needs no special handling here.

@MainActor
final class DictationAnywhereService: ObservableObject {
    static let shared = DictationAnywhereService()
    private init() {}

    // MARK: - Published (drives DictationHUD)

    @Published private(set) var isDictating = false
    /// Live transcript shown in the HUD while the key is held.
    @Published private(set) var livePreview = ""

    // MARK: - Private

    private let dictate = AssemblyAIStreamingService.shared
    private var previewCancellable: AnyCancellable?
    private var started = false

    // Always-on Realtime was paused for this session; restore it on release.
    private var didPauseAlwaysOn = false

    // AssemblyAI delivers a trailing final_transcript slightly after key-up.
    // Mirrors the RealtimeVoiceService PTT tail.
    private let commitTailSeconds: TimeInterval = 0.35

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .miraDictateBegan, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { DictationAnywhereService.shared.begin() } }

        NotificationCenter.default.addObserver(
            forName: .miraDictateEnded, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { DictationAnywhereService.shared.end() } }
    }

    // MARK: - Capture

    private func begin() {
        guard !isDictating else { return }

        // Free the mic from always-on Realtime so it doesn't answer our dictation.
        let realtime = RealtimeVoiceService.shared
        if realtime.isAlwaysOnActive {
            didPauseAlwaysOn = true
            realtime.disconnectAlwaysOn()
        }

        livePreview = ""
        do {
            try dictate.startStreaming()
        } catch {
            NSLog("[DictateAnywhere] start failed: \(error.localizedDescription)")
            restoreAudioOwners()
            return
        }
        isDictating = true

        // Stream partials into the HUD.
        previewCancellable = dictate.$partial
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: String) in
                guard let self, self.isDictating else { return }
                self.livePreview = self.dictate.fullTranscript
            }

        AudioCueService.shared.warmHardware()
        PostHogService.shared.capture("dictate_anywhere_begin")
        NSLog("[DictateAnywhere] listening")
    }

    private func end() {
        guard isDictating else { return }

        // Let the final transcript settle, then commit once.
        DispatchQueue.main.asyncAfter(deadline: .now() + commitTailSeconds) { [weak self] in
            guard let self else { return }
            let transcript = self.dictate.fullTranscript
            self.dictate.stopStreaming()
            self.previewCancellable?.cancel()
            self.previewCancellable = nil
            self.isDictating = false
            self.livePreview = ""
            self.restoreAudioOwners()
            self.commit(transcript)
        }
    }

    private func restoreAudioOwners() {
        if didPauseAlwaysOn {
            didPauseAlwaysOn = false
            RealtimeVoiceService.shared.connectAlwaysOn()
        }
    }

    // MARK: - Insertion

    private func commit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSLog("[DictateAnywhere] nothing transcribed")
            return
        }

        // Primary: caret-insert via Accessibility (no clipboard, no keystrokes).
        if AXActuationService.shared.insertTextAtSystemFocus(text) {
            PostHogService.shared.capture("dictate_anywhere_commit", properties: ["path": "ax"])
            NSLog("[DictateAnywhere] inserted \(text.count) chars via AX")
            return
        }

        // Fallback: pasteboard + ⌘V for AX-poor apps (Electron/Chromium canvases).
        pasteFallback(text)
        PostHogService.shared.capture("dictate_anywhere_commit", properties: ["path": "paste"])
        NSLog("[DictateAnywhere] inserted \(text.count) chars via paste fallback")
    }

    /// Paste `text` into the frontmost app, preserving the user's clipboard.
    private func pasteFallback(_ text: String) {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var wroteAny = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wroteAny = true
                }
            }
            return wroteAny ? copy : nil
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09   // "V"
        if let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }

        // Restore the previous clipboard once the paste has been consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let items = savedItems, !items.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(items)
        }
    }
}
