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
        // Declaration order IS priority order (MacNotch's, verbatim), with
        // `notification` inserted second: an alert that just landed outranks
        // everything except a spinner, because it is the only source here that
        // is time-critical rather than ambient.
        case loading, notification, bluetooth, appUpdates, systemHUD, media, pomodoro, event, todo
    }

    let kind: Kind
    let icon: String
    let text: String
    /// Tint for the icon. Nil uses the neutral secondary colour.
    var tint: Color?
    /// Posting app, when there is one. The strip draws that app's real icon
    /// instead of an SF Symbol — "the app icon and name" is most of what makes
    /// a notification glance readable at a glance.
    var appName: String?

    var id: Int { kind.rawValue }
}

// MARK: - Service

@MainActor
final class LiveActivityService: ObservableObject {

    static let shared = LiveActivityService()

    /// The activity currently on screen, or nil when there is nothing to show.
    @Published private(set) var current: LiveActivity?

    /// Everything with something to say right now, in priority order. Published
    /// so the expanded panel can list what the strip is rotating through —
    /// previously this was computed privately on each tick and thrown away, so
    /// the only way to learn what was active was to watch the strip cycle.
    @Published private(set) var active: [LiveActivity] = []

    /// Pinned activity. While set the strip stops rotating and shows only this
    /// one — MacNotch's per-activity Focus toggle. Nil is the normal rotation.
    @Published private(set) var focusedKind: LiveActivity.Kind?

    private let focusKey = "mira_live_activity_focus_v2"

    /// Pin an activity, or unpin it if it is already pinned. Focusing something
    /// that then goes quiet falls back to the rotation rather than leaving the
    /// strip blank — a pin is a preference about attention, not a promise that
    /// the source will keep talking.
    func toggleFocus(_ kind: LiveActivity.Kind) {
        focusedKind = (focusedKind == kind) ? nil : kind
        if let focusedKind {
            UserDefaults.standard.set(focusedKind.rawValue, forKey: focusKey)
        } else {
            UserDefaults.standard.removeObject(forKey: focusKey)
        }
        refresh(advance: false)
    }

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
        if let raw = UserDefaults.standard.object(forKey: "mira_live_activity_focus_v2") as? Int {
            focusedKind = LiveActivity.Kind(rawValue: raw)
        }

        // Recompute immediately when a source changes rather than waiting for the
        // next tick — a track change should be visible now, not up to 4s later.
        for publisher in [nowPlaying.objectWillChange,
                          pomodoro.objectWillChange,
                          calendar.objectWillChange,
                          // Without this a notification would wait up to the
                          // 4s dwell before the notch reacted, which for the
                          // one time-critical source here is too late to be
                          // a pop at all.
                          SystemNotificationsService.shared.objectWillChange] {
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
        if active != self.active { self.active = active }

        guard !active.isEmpty else {
            current = nil
            rotationIndex = 0
            return
        }

        // A focused activity holds the strip for as long as it has something to
        // say. If it goes quiet the rotation resumes rather than the strip
        // sitting empty, and the pin is kept for when it comes back.
        if let focusedKind, let pinned = active.first(where: { $0.kind == focusedKind }) {
            if pinned != current { current = pinned }
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

        if let note  = notificationActivity() { out.append(note) }
        if let bt    = bluetoothActivity()   { out.append(bt)    }
        if let media = mediaActivity()       { out.append(media) }
        if let pom   = pomodoroActivity()    { out.append(pom)   }
        if let event = nextEventActivity()   { out.append(event) }

        return out.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Only surfaces a LOW battery, never a healthy one. MacNotch lists Bluetooth
    /// as a rotation source, but "AirPods 82%" in a strip you glance at is noise —
    /// the actionable state is the one that will strand you mid-call.
    private func bluetoothActivity() -> LiveActivity? {
        let low = BluetoothService.shared.devices
            .filter { $0.isConnected && $0.isLowBattery && $0.batteryPercent != nil }
            .min { ($0.batteryPercent ?? 100) < ($1.batteryPercent ?? 100) }
        guard let device = low, let pct = device.batteryPercent else { return nil }
        return LiveActivity(kind: .bluetooth,
                            icon: device.icon,
                            text: "\(device.name) \(pct)%",
                            tint: Color(red: 1.0, green: 0.45, blue: 0.45))
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

    /// Two states, deliberately different.
    ///
    /// For the first few seconds after something lands, the closed notch shows
    /// THAT notification — app, and the line itself. After the pop window it
    /// falls back to a count, because a message from twenty minutes ago sitting
    /// permanently in the notch is not a notification any more, it's wallpaper.
    ///
    /// This is also where iPhone notifications appear, without anything extra:
    /// Continuity delivers them into macOS Notification Center, and this reads
    /// Notification Center rather than any one app.
    private func notificationActivity() -> LiveActivity? {
        let service = SystemNotificationsService.shared
        guard service.isTrusted else { return nil }

        if service.isPopping, let latest = service.latest {
            return LiveActivity(kind: .notification,
                                icon: latest.icon,
                                text: "\(latest.app) · \(latest.message)",
                                tint: Color(red: 0.55, green: 0.70, blue: 1.0),
                                appName: latest.app)
        }

        // Cleared ones don't count. A badge that keeps reporting a backlog you
        // have dealt with is exactly the thing Clear exists to stop.
        let count = service.visibleNotifications.count
        guard count > 0 else { return nil }
        return LiveActivity(kind: .notification,
                            icon: "bell.fill",
                            text: count == 1 ? "1 notification" : "\(count) notifications",
                            tint: Color(red: 0.55, green: 0.70, blue: 1.0))
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
                if let appIcon = Self.icon(forApp: activity.appName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: activity.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activity.tint ?? .white.opacity(0.65))
                }
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

    /// Real icon for the posting app, matched by the display name Notification
    /// Center gives us — that is the only identifier the accessibility tree
    /// exposes, so there is no bundle id to look up. Falls back to the SF
    /// Symbol when the app isn't running or the name doesn't match, which is
    /// why the symbol is still chosen for every notification.
    static func icon(forApp name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }), let icon = app.icon else { return nil }
        return icon
    }
}
