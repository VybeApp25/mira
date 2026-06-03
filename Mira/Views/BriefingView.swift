// BriefingView.swift
// Daily briefing shown as the default island tab on first expansion each day.
// Aggregates: calendar events, battery, long-term memory (focus + recent), last conversation.

import SwiftUI
import EventKit

struct BriefingView: View {

    @State private var events:  [EKEvent] = []
    @State private var calAuth: Bool      = false

    private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let surface = Color(red: 0.13, green: 0.13, blue: 0.16)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 0.5)
                .padding(.vertical, 6)
            rightColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await loadCalendar() }
        .onAppear {
            UserDefaults.standard.set(Date(), forKey: "mira_last_briefing")
        }
    }

    // MARK: - Left column: greeting + calendar

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Greeting
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            // Calendar
            VStack(alignment: .leading, spacing: 5) {
                Label("Today", systemImage: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.40))

                if !calAuth {
                    Text("Enable calendar in System Settings")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                } else if events.isEmpty {
                    Text("No events — clear day.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                } else {
                    ForEach(events.prefix(4), id: \.eventIdentifier) { event in
                        eventRow(event)
                    }
                    if events.count > 4 {
                        Text("+\(events.count - 4) more")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.28))
                    }
                }
            }

            Spacer(minLength: 0)

            // Last conversation snippet
            if let snippet = lastConversationSnippet {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Last session", systemImage: "bubble.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                    Text(snippet)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.40))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.trailing, 14)
    }

    // MARK: - Right column: battery + focus + recent memory

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Battery
            if let pct = batteryPercent {
                HStack(spacing: 5) {
                    Image(systemName: batteryCharging ? "battery.100.bolt" : batteryIcon(pct))
                        .font(.system(size: 12))
                        .foregroundColor(batteryColor(pct))
                    Text("\(pct)%\(batteryCharging ? " · charging" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            // Current focus (projects + goals)
            if !focusItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Focus", systemImage: "target")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                    ForEach(focusItems.prefix(3), id: \.id) { mem in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(accent)
                                .frame(width: 4, height: 4)
                            Text(mem.value)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Recently learned
            if !recentMemories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Recently learned", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                    ForEach(recentMemories.prefix(3), id: \.id) { mem in
                        HStack(spacing: 4) {
                            Text(mem.key.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.40))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.20))
                            Text(mem.value)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 220, alignment: .topLeading)
    }

    // MARK: - Calendar row

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(event.calendar.cgColor.map { Color($0) } ?? accent)
                .frame(width: 5, height: 5)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
                    .lineLimit(1)
                Text(event.isAllDay
                     ? "All day"
                     : event.startDate.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.32))
            }
        }
    }

    // MARK: - Computed data

    private var greeting: String {
        let name = MemoryStore.shared.memory(forKey: "user_name")?.value
            ?? MemoryStore.shared.memory(forKey: "name")?.value
            ?? NSFullUserName().components(separatedBy: " ").first
            ?? "there"
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String
        switch hour {
        case 5..<12:  salutation = "Good morning"
        case 12..<17: salutation = "Good afternoon"
        case 17..<22: salutation = "Good evening"
        default:      salutation = "Hey"
        }
        return "\(salutation), \(name)."
    }

    private var batteryPercent: Int? {
        ContextService.shared.capture().batteryPercent
    }
    private var batteryCharging: Bool {
        ContextService.shared.capture().batteryCharging
    }

    private var focusItems: [Memory] {
        MemoryStore.shared.memories
            .filter { ($0.category == .project || $0.category == .goal) && $0.confidence >= 0.6 }
            .sorted { $0.confidence > $1.confidence }
    }

    private var recentMemories: [Memory] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return MemoryStore.shared.memories
            .filter { $0.updatedAt >= cutoff
                   && $0.category != .project
                   && $0.category != .goal }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var lastConversationSnippet: String? {
        ConversationStore.shared.entries.last(where: { $0.role == "mira" })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .description
    }

    // MARK: - Calendar fetch

    private func loadCalendar() async {
        let store  = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)
        if status.rawValue != 3 && status != .authorized {
            calAuth = false
            return
        }
        calAuth    = true
        let cal    = Calendar.current
        let start  = cal.startOfDay(for: Date())
        let end    = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let pred   = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events     = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Battery helpers

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 75...:  return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        default:      return "battery.25"
        }
    }

    private func batteryColor(_ pct: Int) -> Color {
        if batteryCharging { return Color(red: 0.20, green: 0.84, blue: 0.29) }
        switch pct {
        case 20...: return .white.opacity(0.65)
        case 10..<20: return Color(red: 1.0, green: 0.75, blue: 0.20)
        default: return Color(red: 1.0, green: 0.35, blue: 0.35)
        }
    }
}

// MARK: - CGColor → SwiftUI Color (local, avoids HomeTabView conflict)

private extension Color {
    init?(_ cg: CGColor) {
        guard let ns = NSColor(cgColor: cg) else { return nil }
        self = Color(ns)
    }
}
