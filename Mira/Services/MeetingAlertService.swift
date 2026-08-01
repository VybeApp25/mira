// MeetingAlertService.swift
// The meeting alert that takes over the notch (parity audit, demo-03): title,
// time, duration, location, a Join button, Snooze / Dismiss / Dismiss All, and
// a live counter that keeps counting once the meeting has started.
//
// The audit recorded this as 🟡 "EventToastView exists". It doesn't, in any
// useful sense — EventToastView is a small capsule for voice and agent pill
// states (listening, thinking, complete) and has nothing to do with calendars.
// This is new, but it needs no new data: CalendarTodayService already reads the
// events, so the whole feature is deciding when to interrupt and what to offer.

import Foundation
import Combine
import EventKit
import AppKit

// MARK: - Model

struct MeetingAlert: Identifiable, Equatable {

    /// A recognised video-meeting link found on the event.
    struct JoinTarget: Equatable {
        let provider: String       // "Microsoft Teams", "Zoom", …
        let url: URL

        var buttonTitle: String { "Join \(provider)" }
    }

    let id: String                 // event identifier
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let calendarName: String
    let join: JoinTarget?

    var duration: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    var hasStarted: Bool { start <= Date() }
}

// MARK: - Service

@MainActor
final class MeetingAlertService: ObservableObject {

    static let shared = MeetingAlertService()

    /// Non-nil while the notch should be showing an alert.
    @Published private(set) var alert: MeetingAlert?

    /// How early to interrupt. Long enough to get somewhere, short enough that
    /// it isn't sitting there through your morning.
    static let leadTime: TimeInterval = 5 * 60

    /// Stop offering an alert this long after the meeting began — past that you
    /// either joined or you aren't going to.
    static let staleAfter: TimeInterval = 10 * 60

    static let snoozeDuration: TimeInterval = 5 * 60

    private let calendar = CalendarTodayService.shared
    private var timer: AnyCancellable?

    /// Event ids the user has dealt with, and until when. Snooze and dismiss are
    /// the same mechanism with different deadlines — dismiss just runs to the
    /// end of time as far as this alert is concerned.
    private var suppressed: [String: Date] = [:]

    private let suppressedKey = "mira_meeting_alerts_suppressed_v1"

    private init() {
        load()
    }

    func start() {
        guard timer == nil else { return }
        evaluate()
        timer = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.evaluate() }
    }

    func stop() { timer = nil }

    // MARK: Decisions

    func snooze() {
        guard let alert else { return }
        suppress(alert.id, until: Date().addingTimeInterval(Self.snoozeDuration))
        self.alert = nil
    }

    func dismiss() {
        guard let alert else { return }
        suppress(alert.id, until: .distantFuture)
        self.alert = nil
    }

    /// Everything on today's calendar, not just the one on screen. The point of
    /// Dismiss All is a morning of back-to-backs you already know about.
    func dismissAll() {
        for event in todaysEvents() {
            guard let id = event.eventIdentifier else { continue }
            suppress(id, until: .distantFuture)
        }
        alert = nil
    }

    /// Opens the meeting link. Only ever called from the button the user
    /// presses, and the destination host is shown next to it so a link that
    /// arrived in a calendar invite isn't followed blind.
    func join() {
        guard let target = alert?.join else { return }
        NSWorkspace.shared.open(target.url)
        dismiss()
    }

    private func suppress(_ id: String, until: Date) {
        suppressed[id] = until
        persist()
    }

    // MARK: Evaluation

    private func evaluate() {
        let now = Date()
        suppressed = suppressed.filter { $0.value > now }

        let candidate = todaysEvents()
            .filter { event in
                guard let id = event.eventIdentifier else { return false }
                if let until = suppressed[id], until > now { return false }
                // In the window: starting soon, or started recently.
                let untilStart = event.startDate.timeIntervalSince(now)
                if untilStart > Self.leadTime { return false }
                if -untilStart > Self.staleAfter { return false }
                // A meeting that has already ended is not an alert.
                return event.endDate > now
            }
            .min { $0.startDate < $1.startDate }

        alert = candidate.map(Self.makeAlert)
    }

    private func todaysEvents() -> [EKEvent] {
        let today = Calendar.current.startOfDay(for: Date())
        return (calendar.eventsByDay[today] ?? []).filter { !$0.isAllDay }
    }

    private static func makeAlert(_ event: EKEvent) -> MeetingAlert {
        MeetingAlert(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            calendarName: event.calendar?.title ?? "",
            join: joinTarget(for: event))
    }

    // MARK: Join links

    /// Hosts we can name, in the order we'd rather match them.
    private static let providers: [(fragment: String, name: String)] = [
        ("teams.microsoft.com",  "Microsoft Teams"),
        ("teams.live.com",       "Microsoft Teams"),
        ("zoom.us",              "Zoom"),
        ("meet.google.com",      "Google Meet"),
        ("webex.com",            "Webex"),
        ("whereby.com",          "Whereby"),
        ("chime.aws",            "Chime"),
        ("gotomeeting.com",      "GoToMeeting")
    ]

    /// Look for a meeting link on the event.
    ///
    /// EventKit's own `url` first, since that is where a well-formed invite puts
    /// it, then the notes and the location, which is where most real invites put
    /// it instead.
    static func joinTarget(for event: EKEvent) -> MeetingAlert.JoinTarget? {
        if let url = event.url, let match = provider(for: url) {
            return .init(provider: match, url: url)
        }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let found = firstMeetingURL(in: text) { return found }
        }
        return nil
    }

    private static func provider(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return providers.first { host.contains($0.fragment) }?.name
    }

    private static func firstMeetingURL(in text: String) -> MeetingAlert.JoinTarget? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let name = provider(for: url) else { continue }
            return .init(provider: name, url: url)
        }
        return nil
    }

    // MARK: Persistence

    private func persist() {
        let encoded = suppressed.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(encoded, forKey: suppressedKey)
    }

    private func load() {
        guard let raw = UserDefaults.standard.dictionary(forKey: suppressedKey) as? [String: Double]
        else { return }
        suppressed = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
