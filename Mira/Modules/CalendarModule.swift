// CalendarModule.swift
// MacNotch's Calendar module: upcoming events and reminders from macOS, with a
// month grid beside an agenda. This is the two-column "index + detail" layout
// the parity audit identified as MacNotch's dominant grammar — nearly every one
// of its panels is a narrow left index against a wide right detail pane.
//
// Built on the existing CalendarTodayService (EKEventStore, week loading,
// permission handling) rather than a second event store.
//
// Not yet matched: search across title/location/notes, reminder filters, and
// Focus meeting-awareness. Those are additive on top of this layout.

import SwiftUI
import EventKit
import Combine

@MainActor
final class CalendarModule: NotchModule, ObservableObject {

    let id    = "calendar"
    let title = "Calendar"
    let icon  = "calendar"

    /// A month grid next to an agenda needs the room; this is genuinely a
    /// content-dense panel rather than a glance.
    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = CalendarTodayService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return NotchHeaderSubtitle(text: fmt.string(from: service.selectedDate))
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [
            NotchHeaderAccessory(id: "today",
                                 systemImage: "arrow.uturn.backward",
                                 label: "Jump to today") { [weak self] in
                self?.service.selectedDate = Calendar.current.startOfDay(for: Date())
            }
        ]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() { service.requestAccess() }

    func makeContent() -> AnyView { AnyView(CalendarModuleView(service: service)) }
}

// MARK: - View

private struct CalendarModuleView: View {

    @ObservedObject var service: CalendarTodayService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }
    private let cal = Calendar.current

    var body: some View {
        HStack(spacing: 0) {
            monthGrid
                .frame(width: 250)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5)
            agenda
                .frame(maxWidth: .infinity)
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    // MARK: - Left: month grid

    private var monthGrid: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.30))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: service.selectedDate)
        let isToday    = cal.isDateInToday(day)
        let inMonth    = cal.isDate(day, equalTo: service.selectedDate, toGranularity: .month)
        let hasEvents  = !(service.eventsByDay[cal.startOfDay(for: day)] ?? []).isEmpty

        return Button {
            service.selectedDate = cal.startOfDay(for: day)
        } label: {
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundColor(inMonth ? .white.opacity(isSelected ? 1 : 0.80)
                                             : .white.opacity(0.22))
                // Presence dot — the cheapest possible "something happens here"
                // signal, and the reason the grid is worth showing at all.
                Circle()
                    .fill(hasEvents ? accent.opacity(0.85) : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.30) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
    }

    /// Weeks starting Monday, covering the selected month.
    private var weeks: [[Date]] {
        guard let monthRange = cal.range(of: .day, in: .month, for: service.selectedDate),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: service.selectedDate))
        else { return [] }

        // Monday-first offset: Calendar's weekday is 1=Sunday.
        let weekdayOfFirst = (cal.component(.weekday, from: first) + 5) % 7
        let start = cal.date(byAdding: .day, value: -weekdayOfFirst, to: first) ?? first
        let total = weekdayOfFirst + monthRange.count
        let rows = Int(ceil(Double(total) / 7.0))

        return (0..<rows).map { r in
            (0..<7).compactMap { c in
                cal.date(byAdding: .day, value: r * 7 + c, to: start)
            }
        }
    }

    // MARK: - Right: agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !service.permitted {
                permissionPrompt
            } else if todaysEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(todaysEvents, id: \.eventIdentifier) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var todaysEvents: [EKEvent] {
        (service.eventsByDay[cal.startOfDay(for: service.selectedDate)] ?? [])
            .sorted { $0.startDate < $1.startDate }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Calendar colour bar — the only place the user's own colour coding
            // survives, so worth carrying through.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: event.calendar.color ?? .systemBlue))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(event.isAllDay ? "All day" : timeRange(event))
                    if let loc = event.location, !loc.isEmpty {
                        Text("·")
                        Text(loc).lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
    }

    private func timeRange(_ e: EKEvent) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "\(f.string(from: e.startDate)) – \(f.string(from: e.endDate))"
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.25))
            Text("No events")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.30))
            Text("Calendar access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text("Grant access in System Settings › Privacy")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
