import AppKit
import Foundation

// MARK: - CallDetector
//
// Watches for known call/meeting apps becoming active so Mira can auto-pop the
// transcription card. Phase-A scope: detect by running-application bundle ID.
// The "is a call actually happening (vs. the app merely being open)" refinement
// — pairing this with a microphone-in-use signal — lands with the capture engine
// in Phase B (see [[mira-meeting-assistant-spec]]). A manual start path uses the
// same `activate(source:)` entry point so the rest of the pipeline is identical.

@MainActor
final class CallDetector: ObservableObject {
    static let shared = CallDetector()
    private init() {}

    /// Currently detected call source, or nil when no known call app is active.
    @Published private(set) var activeSource: CallSource?

    /// Fired when a call starts (a known app appears) and ends (it goes away).
    var onCallStart: ((CallSource) -> Void)?
    var onCallEnd:   (() -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 3

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Detection

    /// Returns a known call source only when a call app is the FRONTMOST app —
    /// the reliable "you're actually on this call" signal. Matching any *running*
    /// app mislabels (e.g. Discord idle in the background while you take a phone
    /// call). A phone call with no Mac call app in front yields nil (correct —
    /// Mira can't capture the phone's audio).
    func detectedSource() -> CallSource? {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
        return CallSource.from(bundleIdentifier: bid)
    }

    private func evaluate() {
        let detected = detectedSource()
        guard detected != activeSource else { return }

        if let detected {
            activeSource = detected
            onCallStart?(detected)
        } else {
            activeSource = nil
            onCallEnd?()
        }
    }

    // MARK: Manual control (shares the same path as auto-detection)

    /// Force-start a session for a given source (e.g. a "Start transcription"
    /// button, or a browser call we detect out-of-band).
    func activate(source: CallSource) {
        guard activeSource != source else { return }
        activeSource = source
        onCallStart?(source)
    }

    /// Force-end the current session (manual stop).
    func deactivate() {
        guard activeSource != nil else { return }
        activeSource = nil
        onCallEnd?()
    }
}
