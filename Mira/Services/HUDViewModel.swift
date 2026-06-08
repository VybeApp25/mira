import Foundation
import SwiftUI

// MARK: - HUDViewModel

/// Central observable for the notch HUD. Drives statusText, chip visibility,
/// and expansion from a pure HUDReducer + ThrottledStatusUpdater.
/// Wire events in from VoiceService, RouterService, and AgentJobStore.
@MainActor
final class HUDViewModel: ObservableObject {

    static let shared = HUDViewModel()

    @Published private(set) var state:       HUDState = .idle
    @Published private(set) var statusText:  String   = ""
    @Published              var isExpanded:  Bool     = false
    @Published              var isPinned:    Bool     = false
    @Published private(set) var isVisible:  Bool     = false

    private let updater     = ThrottledStatusUpdater()
    private var hideTask:   Task<Void, Never>?
    private var expandTask: Task<Void, Never>?

    // Thresholds
    private let slowOperationThreshold: TimeInterval = 1.5  // expand after this
    private let idleHideDelay:          TimeInterval = 3.0  // collapse after idle

    private init() {}

    // MARK: - Public API

    func send(_ event: HUDEvent) {
        let next = HUDReducer.reduce(state, event)
        guard next != state else { return }
        state = next
        updateStatus(for: next)
        updateVisibility(for: next)
    }

    /// Convenience: bridge from RealtimeState (voice service) without
    /// importing the voice module in every caller.
    func syncVoice(isListening: Bool, isSpeaking: Bool, isThinking: Bool) {
        if isListening  { send(.userInvokedVoice) }
        else if isSpeaking  { send(.speechPlaybackStarted(nil)) }
        else if isThinking  { send(.modelRequestStarted(.higherModel)) }
        else if case .listening = state { send(.speechEnded) }
        else if case .speaking  = state { send(.speechPlaybackEnded) }
        else if case .thinking  = state { send(.idleTimeoutReached) }
    }

    // MARK: - Private

    private func updateStatus(for state: HUDState) {
        let next: String = {
            switch state {
            case .idle:                             return ""
            case .listening(let t):                 return t.flatMap { $0.isEmpty ? nil : $0 } ?? "Listening…"
            case .thinking(let route, _):           return route.statusLabel
            case .speaking:                         return "Speaking"
            case .error(let message, _):            return message
            case .muted:                            return "Muted"
            }
        }()

        updater.submit(next) { @MainActor [weak self] value in
            self?.statusText = value
        }
    }

    private func updateVisibility(for state: HUDState) {
        hideTask?.cancel()
        expandTask?.cancel()

        switch state {
        case .idle:
            if !isPinned {
                scheduleHide(after: idleHideDelay)
            }
        case .error:
            isVisible  = true
            isExpanded = true
        case .thinking(let route, let startedAt):
            isVisible = true
            if case .backgroundWorker = route {
                isExpanded = true
            } else {
                scheduleExpansion(startedAt: startedAt)
            }
        case .listening, .speaking, .muted:
            isVisible  = true
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isVisible  = false
            self?.isExpanded = false
        }
    }

    private func scheduleExpansion(startedAt: Date) {
        let alreadyElapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, slowOperationThreshold - alreadyElapsed)
        expandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isExpanded = true
        }
    }
}
