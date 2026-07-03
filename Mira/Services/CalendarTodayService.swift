import Foundation
import EventKit

// MARK: - CalendarTodayService
//
// Backs the notch's Home idle panel calendar day-strip. Distinct from
// MiraToolService's get_calendar_events (which creates a throwaway EKEventStore
// per call and returns a pre-formatted string for chat) — this owns a persistent
// store and structured EKEvent data suitable for a live SwiftUI widget.

@MainActor
final class CalendarTodayService: ObservableObject {
    static let shared = CalendarTodayService()

    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var eventsByDay: [Date: [EKEvent]] = [:]
    @Published private(set) var permitted = false
    @Published private(set) var checked   = false

    private let store = EKEventStore()

    var eventsForSelectedDate: [EKEvent] {
        eventsByDay[Calendar.current.startOfDay(for: selectedDate)] ?? []
    }

    /// The 7 dates shown in the compact day-strip, centered on today.
    var weekDates: [Date] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date())) ?? Date()
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Wider scrollable range (BoringNotch parity: 7 days back, 14 forward) for the
    /// Home tab's snapping horizontal date strip.
    var scrollDates: [Date] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date())) ?? Date()
        return (0..<22).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // Ported verbatim from HomeTabView.swift's CalendarCard.requestAccess() —
    // handles the macOS 14 .fullAccess/requestFullAccessToEvents split correctly.
    func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:                           // pre-macOS 14 grant
            permitted = true; checked = true; loadWeek(); return
        case .denied, .restricted:
            permitted = false; checked = true; return
        default: break   // .notDetermined or .fullAccess (macOS 14) — fall through to request
        }
        if #available(macOS 14.0, *), status.rawValue == 3 {  // .fullAccess = 3
            permitted = true; checked = true; loadWeek(); return
        }
        // Only reaches here when status is .notDetermined — show dialog once
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] ok, _ in
                Task { @MainActor in
                    self?.permitted = ok; self?.checked = true
                    if ok { self?.loadWeek() }
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] ok, _ in
                Task { @MainActor in
                    self?.permitted = ok; self?.checked = true
                    if ok { self?.loadWeek() }
                }
            }
        }
    }

    func loadWeek() {
        let cal = Calendar.current
        var grouped: [Date: [EKEvent]] = [:]
        for day in scrollDates {
            let start = cal.startOfDay(for: day)
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            grouped[start] = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        }
        eventsByDay = grouped
    }
}
