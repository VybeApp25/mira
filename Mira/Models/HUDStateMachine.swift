import Foundation

// MARK: - Route

enum Route: Equatable {
    case local
    case higherModel
    case backgroundWorker(name: String)
    case tool(name: String)

    var statusLabel: String {
        switch self {
        case .local:                        return "Working"
        case .higherModel:                  return "Thinking…"
        case .backgroundWorker(let name):   return "Running \(name)"
        case .tool(let name):               return "Using \(name)"
        }
    }
}

// MARK: - HUD State

enum HUDState: Equatable {
    case idle
    case listening(transcript: String?)
    case thinking(route: Route, startedAt: Date)
    case speaking(textPreview: String?)
    case error(message: String, recoverable: Bool)
    case muted

    var isIdle: Bool { if case .idle = self { return true }; return false }
    var isActive: Bool { !isIdle }
}

// MARK: - HUD Event

enum HUDEvent {
    case userInvokedVoice
    case userSubmittedText(String)
    case speechEnded
    case modelRequestStarted(Route)
    case responseReady(String)
    case speechPlaybackStarted(String?)
    case speechPlaybackEnded
    case toolStarted(String)
    case workerStarted(String)
    case cancelRequested
    case muteToggled(Bool)
    case permissionDenied(String)
    case timeoutReached
    case errorOccurred(String, recoverable: Bool)
    case errorDismissed
    case idleTimeoutReached
}

// MARK: - Reducer (pure — no side effects)

enum HUDReducer {
    static func reduce(_ state: HUDState, _ event: HUDEvent, now: Date = .now) -> HUDState {
        switch (state, event) {

        case (_, .muteToggled(true)):
            return .muted

        case (.muted, .muteToggled(false)):
            return .idle

        case (_, .userInvokedVoice):
            return .listening(transcript: nil)

        case (_, .userSubmittedText):
            return .thinking(route: .higherModel, startedAt: now)

        case (.listening, .speechEnded):
            return .thinking(route: .higherModel, startedAt: now)

        case (_, .modelRequestStarted(let route)):
            return .thinking(route: route, startedAt: now)

        case (_, .toolStarted(let name)):
            return .thinking(route: .tool(name: name), startedAt: now)

        case (_, .workerStarted(let name)):
            return .thinking(route: .backgroundWorker(name: name), startedAt: now)

        case (_, .speechPlaybackStarted(let preview)):
            return .speaking(textPreview: preview)

        case (.speaking, .speechPlaybackEnded):
            return .idle

        case (_, .permissionDenied(let message)):
            return .error(message: message, recoverable: true)

        case (_, .errorOccurred(let message, let recoverable)):
            return .error(message: message, recoverable: recoverable)

        case (.error, .errorDismissed):
            return .idle

        case (_, .cancelRequested):
            return .idle

        case (.idle, .idleTimeoutReached):
            return .idle

        default:
            return state
        }
    }
}

// MARK: - Throttled Status Updater

@MainActor
final class ThrottledStatusUpdater {
    private let minInterval: TimeInterval
    private var lastUpdate: Date = .distantPast
    private var pendingTask: Task<Void, Never>?

    init(minInterval: TimeInterval = 0.35) {
        self.minInterval = minInterval
    }

    func submit(_ text: String, apply: @escaping @Sendable (String) -> Void) {
        pendingTask?.cancel()
        let elapsed = Date().timeIntervalSince(lastUpdate)

        if elapsed >= minInterval {
            lastUpdate = Date()
            apply(text)
            return
        }

        let delay = minInterval - elapsed
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lastUpdate = Date()
            apply(text)
        }
    }
}
