import SwiftUI

// MARK: - Persistent assistant modes (debounced, drive SharedStatusView)

enum PillMode: Equatable {
    case idle, thinking, working, speaking

    var accessibilityLabel: String {
        switch self {
        case .idle:     return "Mira is ready."
        case .thinking: return "Mira is thinking."
        case .working:  return "Mira is working on your request."
        case .speaking: return "Mira is speaking."
        }
    }
}

// MARK: - Transient events (short-lived, do not replace persistent mode)

enum PillEvent: Equatable {
    case shortcut, listening, complete, error, handoff

    var label: String {
        switch self {
        case .shortcut:  return "Mira"
        case .listening: return "Listening"
        case .complete:  return "Done"
        case .error:     return "Needs attention"
        case .handoff:   return "Switching"
        }
    }

    var icon: String {
        switch self {
        case .shortcut:  return "sparkle"
        case .listening: return "waveform"
        case .complete:  return "checkmark.circle.fill"
        case .error:     return "exclamationmark.circle.fill"
        case .handoff:   return "arrow.right.circle.fill"
        }
    }
}

// MARK: - State model

@MainActor
final class PillStateModel: ObservableObject {
    @Published private(set) var mode:  PillMode   = .idle
    @Published private(set) var event: PillEvent? = nil

    private var pendingMode:    PillMode?
    private var debounceTask:   DispatchWorkItem?
    private var eventClearTask: DispatchWorkItem?

    // 180 ms debounce — absorbs rapid idle↔thinking↔working transitions
    private let debounceInterval: TimeInterval = 0.18

    func setMode(_ newMode: PillMode) {
        guard newMode != (pendingMode ?? mode) else { return }
        debounceTask?.cancel()
        pendingMode = newMode
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingMode else { return }
            withAnimation(.easeInOut(duration: 0.15)) { self.mode = pending }
            self.pendingMode = nil
            AccessibilityService.shared.announce(pending.accessibilityLabel)
            AudioCueService.shared.playModeChange(pending)
        }
        debounceTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func postEvent(_ newEvent: PillEvent) {
        eventClearTask?.cancel()
        withAnimation(.easeInOut(duration: 0.12)) { event = newEvent }
        AudioCueService.shared.playEvent(newEvent)
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.20)) { self?.event = nil }
        }
        eventClearTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // Sync from the existing RealtimeState so we don't duplicate the source of truth.
    func syncFromRealtime(_ state: RealtimeState, isListening: Bool, isLoading: Bool) {
        let newMode: PillMode
        switch state {
        case .idle:
            newMode = (isListening || isLoading) ? .working : .idle
        case .connecting, .transcribing:
            newMode = .working
        case .recording:
            newMode = .working
        case .thinking:
            newMode = .thinking
        case .speaking:
            newMode = .speaking
        case .error:
            newMode = .idle   // error state → idle; caller posts the .error event separately
        }
        setMode(newMode)
    }
}
