import Foundation
import Combine

// Singleton Pomodoro / interval timer that persists across dock redraws.
// States: idle → running → paused → (break) → running…
//
// Beyond the cycle machine this owns the two things the MacNotch parity audit
// scored missing (docs/specs/macnotch-parity-audit.md §"Pomodoro"): a reorderable
// PRESET list, and a FOCUS TARGET that ties a run to something on today's
// schedule. Both live here rather than in the module so the dock widget, the
// collapsed live-activity strip and the notch panel all read one state.

@MainActor
final class PomodoroService: ObservableObject {
    static let shared = PomodoroService()

    /// Raw-valued so presets can be persisted. The cases are unchanged — the
    /// live-activity strip and the dock widget switch on them.
    enum Phase: String, Codable { case focus, shortBreak, longBreak }

    @Published private(set) var isRunning    = false
    @Published private(set) var secondsLeft  = 25 * 60
    @Published private(set) var phase        = Phase.focus
    @Published private(set) var completed    = 0   // focus sessions done

    var focusMins:      Int { UserDefaults.standard.integer(forKey: "pom_focus")      .nonZero ?? 25 }
    var shortBreakMins: Int { UserDefaults.standard.integer(forKey: "pom_short")      .nonZero ?? 5  }
    var longBreakMins:  Int { UserDefaults.standard.integer(forKey: "pom_long")       .nonZero ?? 15 }
    var sessionsPerSet: Int { UserDefaults.standard.integer(forKey: "pom_sessions")   .nonZero ?? 4  }

    private var timer: AnyCancellable?

    private init() {
        presets     = Self.loadPresets()
        focusTarget = Self.loadFocusTarget()
        reset()
    }

    // MARK: - Presets

    /// A one-tap way to start a run. Built-ins deliberately carry NO duration:
    /// they resolve against `pom_focus` / `pom_short` / `pom_long` at start time,
    /// so changing the length in Settings changes the preset too. Storing a copy
    /// of the minutes here is how a preset list silently drifts out of agreement
    /// with the settings pane that claims to control it.
    struct Preset: Identifiable, Codable, Equatable {
        let id: String
        var name: String
        var phase: Phase
        var systemImage: String
        /// Set only for presets that are their own duration (Quick, Custom).
        var minutesOverride: Int?

        var isBuiltIn: Bool { minutesOverride == nil }
    }

    @Published private(set) var presets: [Preset]

    private static let presetsKey = "pom_presets_v1"

    static let factoryPresets: [Preset] = [
        Preset(id: "work",   name: "Work",        phase: .focus,      systemImage: "brain.head.profile", minutesOverride: nil),
        Preset(id: "short",  name: "Short Break", phase: .shortBreak, systemImage: "cup.and.saucer",     minutesOverride: nil),
        Preset(id: "long",   name: "Long Break",  phase: .longBreak,  systemImage: "figure.walk",        minutesOverride: nil),
        Preset(id: "quick",  name: "Quick Timer", phase: .focus,      systemImage: "bolt",               minutesOverride: 5),
        Preset(id: "custom", name: "Custom",      phase: .focus,      systemImage: "slider.horizontal.3", minutesOverride: 45)
    ]

    private static func loadPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let saved = try? JSONDecoder().decode([Preset].self, from: data),
              !saved.isEmpty
        else { return factoryPresets }

        // Keep the user's order, but let a factory preset added by a later build
        // appear instead of being invisible until they reset. Same reasoning as
        // NotchModuleRegistry's seen-ids pinning.
        let known = Set(saved.map(\.id))
        return saved + factoryPresets.filter { !known.contains($0.id) }
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.presetsKey)
    }

    /// Resolved length in minutes — the override when there is one, otherwise
    /// whatever Settings currently says for that phase.
    func minutes(for preset: Preset) -> Int {
        if let m = preset.minutesOverride { return m }
        switch preset.phase {
        case .focus:      return focusMins
        case .shortBreak: return shortBreakMins
        case .longBreak:  return longBreakMins
        }
    }

    /// Load a preset and run it. Does not touch `completed` — a break taken out
    /// of order shouldn't reset your session count for the set.
    func start(_ preset: Preset) {
        pause()
        activePresetID = preset.id
        phase          = preset.phase
        secondsLeft    = minutes(for: preset) * 60
        start()
    }

    /// Which preset produced the current run, for highlighting the list. Cleared
    /// by `reset()` and by the automatic phase advance, because after the machine
    /// moves you to a break you are no longer running the preset you picked.
    @Published private(set) var activePresetID: String?

    func setMinutes(_ minutes: Int, for presetID: String) {
        guard let idx = presets.firstIndex(where: { $0.id == presetID }),
              presets[idx].minutesOverride != nil else { return }
        presets[idx].minutesOverride = max(1, min(180, minutes))
        persistPresets()
        // Reflect the change immediately if that preset is what's on the clock.
        if activePresetID == presetID, !isRunning {
            secondsLeft = presets[idx].minutesOverride! * 60
        }
    }

    func movePreset(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        persistPresets()
    }

    // MARK: - Focus target

    /// Something on today's schedule this run is FOR. Stored by identifier and
    /// title together: the title is what the notch shows, and re-resolving an
    /// EventKit item every render just to draw a string is both slow and prone to
    /// showing nothing when access is momentarily unavailable.
    struct FocusTarget: Codable, Equatable {
        enum Kind: String, Codable { case event, reminder }
        let id: String
        let title: String
        let kind: Kind
    }

    @Published var focusTarget: FocusTarget? {
        didSet { persistFocusTarget() }
    }

    private static let focusTargetKey = "pom_focus_target_v1"

    private static func loadFocusTarget() -> FocusTarget? {
        guard let data = UserDefaults.standard.data(forKey: focusTargetKey) else { return nil }
        return try? JSONDecoder().decode(FocusTarget.self, from: data)
    }

    private func persistFocusTarget() {
        guard let target = focusTarget, let data = try? JSONEncoder().encode(target) else {
            UserDefaults.standard.removeObject(forKey: Self.focusTargetKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.focusTargetKey)
    }

    // MARK: - Transport

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

    /// Manual skip. Distinct from a phase running out: no completion sound, and
    /// it does not bank a focus session you didn't sit through.
    func skip() {
        advance(completedNaturally: false)
    }

    func reset() {
        pause()
        phase          = .focus
        completed      = 0
        secondsLeft    = focusMins * 60
        activePresetID = nil
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
            advance(completedNaturally: true)
        }
    }

    private func advance(completedNaturally: Bool) {
        pause()
        activePresetID = nil
        if completedNaturally { AudioCueService.shared.play(.agentDone) }

        switch phase {
        case .focus:
            if completedNaturally { completed += 1 }
            if completed % sessionsPerSet == 0 && completed > 0 {
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
