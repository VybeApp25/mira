// DayProgressModule.swift
// MacNotch's Day Progress: one timeline for today built from calendar events,
// reminders and tasks, with a completion bar and a "next in Nm" pill. Scored ❌
// in the audit (zero DayProgress hits).
//
// Pure composition — CalendarTodayService and RemindersService are already
// wired, so this adds no new data source, permission or polling. It is the first
// module that exists only to RELATE things Mira already knew separately, which
// is also the argument for the module system paying off.
//
// The timeline spans waking hours rather than midnight-to-midnight. A 24h axis
// spends a third of its width on hours you were asleep, which squeezes the part
// you actually care about into the middle.

import SwiftUI
import EventKit
import Combine

// MARK: - Model

private struct TimelineItem: Identifiable {
    enum Kind { case event, reminder }
    let id: String
    let kind: Kind
    let title: String
    let start: Date
    let end: Date?
    let isDone: Bool
    let color: Color
}

// MARK: - Module

@MainActor
final class DayProgressModule: NotchModule, ObservableObject {

    let id    = "dayprogress"
    let title = "Day Progress"
    let icon  = "chart.bar.xaxis"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    private let calendar  = CalendarTodayService.shared
    private let reminders = RemindersService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Waking window. Deliberately not user-configurable yet — MacNotch exposes
    /// a bedtime marker in settings, and guessing at a schedule the user never
    /// told us is worse than a sane fixed window.
    static let dayStartHour = 7
    static let dayEndHour   = 23

    var subtitle: NotchHeaderSubtitle? {
        NotchHeaderSubtitle(text: "\(Int(Self.dayFraction * 100))%")
    }

    /// How far through the waking day we are, clamped at the edges.
    static var dayFraction: Double {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: now),
              let end   = cal.date(bySettingHour: dayEndHour,   minute: 0, second: 0, of: now)
        else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    init() {
        for p in [calendar.objectWillChange, reminders.objectWillChange] {
            p.sink { [weak self] _ in self?.objectWillChange.send() }
             .store(in: &cancellables)
        }
    }

    func didAppear() {
        calendar.requestAccess()
        reminders.requestAccess()
    }

    func makeContent() -> AnyView {
        AnyView(DayProgressView(calendar: calendar, reminders: reminders))
    }
}

// MARK: - View

private struct DayProgressView: View {

    @ObservedObject var calendar: CalendarTodayService
    @ObservedObject var reminders: RemindersService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }
    private let cal = Calendar.current

    var body: some View {
        // Re-render each minute so the now-marker and the "next in" pill stay true
        // without polling anything.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                header
                timeline
                upcoming
                Spacer(minLength: 0)
            }
            .padding(.top, NotchModuleShellView.headerHeight + 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Color.black)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(nextPill)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Spacer(minLength: 0)
            Text("\(doneCount)/\(items.count) done")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.40))
        }
    }

    private var nextPill: String {
        guard let next = items
            .filter({ !$0.isDone && $0.start > Date() })
            .min(by: { $0.start < $1.start })
        else { return "Nothing left today" }
        let mins = max(1, Int(next.start.timeIntervalSinceNow / 60))
        if mins >= 60 { return "\(next.title) in \(mins / 60)h \(mins % 60)m" }
        return "\(next.title) in \(mins)m"
    }

    private var doneCount: Int {
        items.filter { $0.isDone || ($0.end ?? $0.start) < Date() }.count
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))

                    // Elapsed portion of the waking day.
                    Capsule()
                        .fill(accent.opacity(0.30))
                        .frame(width: geo.size.width * DayProgressModule.dayFraction)

                    // Items plotted at their position in the day.
                    ForEach(items) { item in
                        let x = fraction(of: item.start) * geo.size.width
                        let w = max(3, widthFraction(of: item) * geo.size.width)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color.opacity(item.isDone ? 0.35 : 0.95))
                            .frame(width: w, height: 14)
                            .offset(x: min(x, geo.size.width - w))
                            .help(item.title)
                    }

                    // Now marker sits on top of everything.
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5, height: 20)
                        .offset(x: geo.size.width * DayProgressModule.dayFraction)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
            }
            .frame(height: 20)

            HStack {
                Text(hourLabel(DayProgressModule.dayStartHour))
                Spacer()
                Text(hourLabel((DayProgressModule.dayStartHour + DayProgressModule.dayEndHour) / 2))
                Spacer()
                Text(hourLabel(DayProgressModule.dayEndHour))
            }
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.32))
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "AM" : "PM"
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display)\(suffix)"
    }

    /// Position of a date within the waking window, 0...1.
    private func fraction(of date: Date) -> Double {
        let now = Date()
        guard let start = cal.date(bySettingHour: DayProgressModule.dayStartHour,
                                   minute: 0, second: 0, of: now),
              let end = cal.date(bySettingHour: DayProgressModule.dayEndHour,
                                 minute: 0, second: 0, of: now)
        else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }

    private func widthFraction(of item: TimelineItem) -> Double {
        guard let end = item.end else { return 0.004 }   // point-in-time reminder
        return max(0.004, fraction(of: end) - fraction(of: item.start))
    }

    // MARK: Upcoming list

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.filter { ($0.end ?? $0.start) >= Date() }.prefix(3)) { item in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(item.color)
                        .frame(width: 3, height: 16)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
            if items.isEmpty {
                Text("Nothing scheduled today")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    // MARK: Data

    /// Calendar events plus reminders due today, merged onto one axis. This
    /// merge IS the module — both halves already existed separately.
    private var items: [TimelineItem] {
        var out: [TimelineItem] = []

        let events = calendar.eventsByDay[cal.startOfDay(for: Date())] ?? []
        for e in events where !e.isAllDay {
            out.append(TimelineItem(
                id: e.eventIdentifier ?? UUID().uuidString,
                kind: .event,
                title: e.title ?? "Untitled",
                start: e.startDate,
                end: e.endDate,
                isDone: e.endDate < Date(),
                color: Color(nsColor: e.calendar.color ?? .systemBlue)
            ))
        }

        for r in reminders.reminders {
            guard let due = r.dueDateComponents?.date,
                  cal.isDateInToday(due) else { continue }
            out.append(TimelineItem(
                id: r.calendarItemIdentifier,
                kind: .reminder,
                title: r.title ?? "Reminder",
                start: due,
                end: nil,
                isDone: r.isCompleted,
                color: Color(red: 0.98, green: 0.72, blue: 0.35)
            ))
        }

        return out.sorted { $0.start < $1.start }
    }
}
