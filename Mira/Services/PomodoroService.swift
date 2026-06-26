import Foundation
import Combine

// Singleton Pomodoro / interval timer that persists across dock redraws.
// States: idle → running → paused → (break) → running…

@MainActor
final class PomodoroService: ObservableObject {
    static let shared = PomodoroService()

    enum Phase { case focus, shortBreak, longBreak }

    @Published private(set) var isRunning    = false
    @Published private(set) var secondsLeft  = 25 * 60
    @Published private(set) var phase        = Phase.focus
    @Published private(set) var completed    = 0   // focus sessions done

    var focusMins:      Int { UserDefaults.standard.integer(forKey: "pom_focus")      .nonZero ?? 25 }
    var shortBreakMins: Int { UserDefaults.standard.integer(forKey: "pom_short")      .nonZero ?? 5  }
    var longBreakMins:  Int { UserDefaults.standard.integer(forKey: "pom_long")       .nonZero ?? 15 }
    var sessionsPerSet: Int { UserDefaults.standard.integer(forKey: "pom_sessions")   .nonZero ?? 4  }

    private var timer: AnyCancellable?

    private init() { reset() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func pause() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    func skip() {
        advance()
    }

    func reset() {
        pause()
        phase       = .focus
        completed   = 0
        secondsLeft = focusMins * 60
    }

    func setFocusMins(_ v: Int) {
        UserDefaults.standard.set(v, forKey: "pom_focus")
        if phase == .focus { secondsLeft = v * 60 }
    }

    // MARK: - Internal

    private func tick() {
        if secondsLeft > 0 {
            secondsLeft -= 1
        } else {
            advance()
        }
    }

    private func advance() {
        pause()
        switch phase {
        case .focus:
            completed += 1
            if completed % sessionsPerSet == 0 {
                phase       = .longBreak
                secondsLeft = longBreakMins * 60
            } else {
                phase       = .shortBreak
                secondsLeft = shortBreakMins * 60
            }
        case .shortBreak, .longBreak:
            phase       = .focus
            secondsLeft = focusMins * 60
        }
    }
}

extension Int {
    fileprivate var nonZero: Int? { self == 0 ? nil : self }
}
