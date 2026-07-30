// LiveActivityService.swift
// The rotating collapsed strip — MacNotch's "Live Activities": when the notch is
// closed it cycles media, timers, calendar, Bluetooth and app updates rather than
// sitting inert. You spend most of your time looking at the collapsed state, so
// this is disproportionately what "feels like MacNotch" means.
//
// Priority order is MacNotch's own, decoded from its `liveActivityPriorityOrderData`
// preference (a plist blob): loading, bluetooth, appUpdates, systemHUD, media,
// pomodoro, event, todo. Mira has real sources for media, pomodoro and event today;
// the rest are declared so the ordering doesn't change when they land.
//
// IMPORTANT — voice preempts everything. Mira's collapsed pill is how you know it
// is listening, thinking, or speaking, and that is not decoration to rotate past.
// So this drives the pill ONLY while voice is idle; MiraIslandView gives the
// existing voice/agent/pointing states priority and falls through to here.

import SwiftUI
import Combine
import EventKit

// MARK: - Model

struct LiveActivity: Equatable, Identifiable {
    enum Kind: Int, CaseIterable {
        // Declaration order IS priority order (MacNotch's, verbatim).
        case loading, bluetooth, appUpdates, systemHUD, media, pomodoro, event, todo
    }

    let kind: Kind
    let icon: String
    let text: String
    /// Tint for the icon. Nil uses the neutral secondary colour.
    var tint: Color?

    var id: Int { kind.rawValue }
}

// MARK: - Service

@MainActor
final class LiveActivityService: ObservableObject {

    static let shared = LiveActivityService()

    /// The activity currently on screen, or nil when there is nothing to show.
    @Published private(set) var current: LiveActivity?

    /// Seconds each activity holds before rotating. MacNotch widens briefly on a
    /// track change; a fixed dwell is the honest first version of that.
    private static let dwell: TimeInterval = 4.0

    private var rotationIndex = 0
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let nowPlaying = NowPlayingService.shared
    private let pomodoro   = PomodoroService.shared
    private let calendar   = CalendarTodayService.shared

    private init() {
        // Recompute immediately when a source changes rather than waiting for the
        // next tick — a track change should be visible now, not up to 4s later.
        for publisher in [nowPlaying.objectWillChange,
                          pomodoro.objectWillChange,
                          calendar.objectWillChange] {
            publisher
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh(advance: false) }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        refresh(advance: false)
        let t = Timer(timeInterval: Self.dwell, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(advance: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        current = nil
    }

    // MARK: - Rotation

    /// Rebuilds the active set and picks what to show. `advance` moves to the next
    /// one; a source change refreshes in place so the strip doesn't skip ahead.
    private func refresh(advance: Bool) {
        let active = activeActivities()
        guard !active.isEmpty else {
            current = nil
            rotationIndex = 0
            return
        }
        if advance {
            rotationIndex = (rotationIndex + 1) % active.count
        } else if rotationIndex >= active.count {
            rotationIndex = 0
        }
        let next = active[rotationIndex]
        // Avoid a pointless crossfade when the content is unchanged.
        if next != current { current = next }
    }

    /// Everything with something to say right now, in MacNotch's priority order.
    private func activeActivities() -> [LiveActivity] {
        var out: [LiveActivity] = []

        if let media = mediaActivity()       { out.append(media) }
        if let pom   = pomodoroActivity()    { out.append(pom)   }
        if let event = nextEventActivity()   { out.append(event) }

        return out.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: - Sources

    private func mediaActivity() -> LiveActivity? {
        let info = nowPlaying.info
        guard info.isPlaying, !info.title.isEmpty else { return nil }
        let text = info.artist.isEmpty ? info.title : "\(info.title) — \(info.artist)"
        return LiveActivity(kind: .media,
                            icon: "music.note",
                            text: text,
                            tint: Color(red: 0.40, green: 0.85, blue: 0.55))
    }

    private func pomodoroActivity() -> LiveActivity? {
        guard pomodoro.isRunning else { return nil }
        let m = pomodoro.secondsLeft / 60
        let s = pomodoro.secondsLeft % 60
        let label: String
        switch pomodoro.phase {
        case .focus:      label = "Focus"
        case .shortBreak: label = "Break"
        case .longBreak:  label = "Long break"
        }
        return LiveActivity(kind: .pomodoro,
                            icon: "timer",
                            text: String(format: "%@ %d:%02d", label, m, s),
                            tint: Color(red: 0.98, green: 0.62, blue: 0.35))
    }

    /// The next event starting within the hour — beyond that it isn't glanceable
    /// information, it's noise.
    private func nextEventActivity() -> LiveActivity? {
        guard calendar.permitted else { return nil }
        let now = Date()
        let events = calendar.eventsByDay[Calendar.current.startOfDay(for: now)] ?? []
        let upcoming = events
            .filter { !$0.isAllDay && $0.startDate > now && $0.startDate < now.addingTimeInterval(3600) }
            .sorted { $0.startDate < $1.startDate }
        guard let next = upcoming.first, let title = next.title else { return nil }

        let mins = max(1, Int(next.startDate.timeIntervalSince(now) / 60))
        return LiveActivity(kind: .event,
                            icon: "calendar",
                            text: "\(title) in \(mins)m",
                            tint: Color(red: 0.55, green: 0.70, blue: 1.0))
    }
}

// MARK: - View

/// Renders the current activity in the collapsed pill. Draws nothing when there is
/// no activity, so an idle Mac keeps the pill indistinguishable from the hardware
/// notch — which is the behavior the collapsed pill already relied on.
struct LiveActivityStrip: View {

    @ObservedObject private var service = LiveActivityService.shared

    var body: some View {
        if let activity = service.current {
            HStack(spacing: 5) {
                Image(systemName: activity.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(activity.tint ?? .white.opacity(0.65))
                Text(activity.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 200, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.28), value: activity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(activity.text)
        }
    }
}
