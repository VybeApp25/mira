// DashboardModule.swift
// MacNotch's flagship panel: named profiles, each a grid of widget slots.
// Scored 🟡 in the parity audit — Mira had nine reorderable dock widgets but no
// profiles, no slot model, and no way to switch layouts by intent.
//
// The header follows their shape exactly (`Dashboard  [Work >]`): title, then a
// tappable profile pill in that profile's own colour. That pill is the module —
// switching from Work to Focus is meant to re-lay the whole panel, not filter it.
//
// Widget bodies come from DockWidgetFactory wherever a dock widget already
// draws the thing. The remaining cards — Events, Day progress, Screen Time,
// Notes, Bluetooth, Quotes — are drawn here, and all six only became possible
// because this branch built the services behind them first.

import SwiftUI
import Combine
import EventKit

@MainActor
final class DashboardModule: NotchModule, ObservableObject {

    let id    = "dashboard"
    let title = "Dashboard"
    let icon  = "square.grid.2x2"

    /// Two rows need the taller panel; one row fits the standard one. Height is
    /// per-module by construction, and MacNotch stores exactly this as
    /// `dashboardTwoRowsNotchExpandedHeight`.
    /// One row is a short panel, two rows a tall one. `.standard` left a third
    /// of the panel empty under a single row of cards.
    var heightLevel: NotchHeightLevel { store.selected.twoRows ? .tall : .compact }
    let allowsTallMode = false

    private let store = DashboardProfileStore.shared
    private var cancellables = Set<AnyCancellable>()

    /// True while the profile picker is open.
    @Published private(set) var pickingProfile = false

    var detailTitle: String? { pickingProfile ? "Dashboard" : nil }
    func popDetail() { pickingProfile = false }

    var subtitle: NotchHeaderSubtitle? {
        if pickingProfile { return NotchHeaderSubtitle(text: "Profiles", isPill: true) }
        switch store.selected.headerDisplay {
        case .dashboard:
            return NotchHeaderSubtitle(text: store.selected.name, isPill: true)
        case .date:
            // The Simple profile shows the date instead of the word, which is
            // the one place MacNotch varies its own header.
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE d MMMM"
            return NotchHeaderSubtitle(text: formatter.string(from: Date()))
        }
    }

    var headerAccessories: [NotchHeaderAccessory] {
        guard !pickingProfile else { return [] }
        return [
            NotchHeaderAccessory(id: "profiles",
                                 systemImage: store.selected.icon,
                                 label: "Switch profile",
                                 isProminent: true) { [weak self] in
                self?.pickingProfile = true
            },
            NotchHeaderAccessory(id: "rows",
                                 systemImage: store.selected.twoRows
                                     ? "rectangle.grid.1x2.fill"
                                     : "rectangle.grid.1x2",
                                 label: store.selected.twoRows
                                     ? "Use one row" : "Use two rows") { [weak self] in
                guard let self else { return }
                self.store.setTwoRows(!self.store.selected.twoRows)
                self.heightChanged()
            }
        ]
    }

    init() {
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didDisappear() { pickingProfile = false }

    func select(_ id: String) {
        store.select(id)
        pickingProfile = false
        // A profile can carry a different row count, so the panel may need to
        // change size the instant you pick one.
        heightChanged()
    }

    func heightChanged() {
        NotificationCenter.default.post(name: .miraIslandHeightChanged, object: nil)
    }

    func makeContent() -> AnyView {
        AnyView(DashboardView(module: self, store: store))
    }
}

// MARK: - View

private struct DashboardView: View {

    @ObservedObject var module: DashboardModule
    @ObservedObject var store: DashboardProfileStore

    var body: some View {
        Group {
            if module.pickingProfile { profilePicker } else { grid }
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    // MARK: Grid

    private var grid: some View {
        let profile = store.selected
        let slots = profile.visibleSlots
        let rows = profile.twoRows ? 2 : 1

        // Widths are computed, not negotiated. Left to an HStack, each card
        // takes its content's ideal width first, so Pomodoro's big 25:00 made
        // its column twice the width of Notes' and the row stopped reading as
        // a grid. A slot is a quarter of the panel whatever is in it.
        return GeometryReader { geo in
            let spacing: CGFloat = 8
            let cardWidth = max(40, (geo.size.width - spacing * 3) / 4)

            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<4, id: \.self) { column in
                            let index = row * 4 + column
                            SlotCard(widget: index < slots.count ? slots[index] : nil,
                                     accent: profile.color)
                                .frame(width: cardWidth)
                                // The dock widgets carry an intrinsic width
                                // larger than a quarter-panel — Pomodoro's
                                // 25:00 is set at 24pt — and drew straight
                                // over their neighbours without this.
                                .clipped()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Profile picker

    private var profilePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(store.profiles) { profile in
                    Button { module.select(profile.id) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 12))
                                .foregroundColor(profile.color)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                                // The layout itself is the only meaningful
                                // description of a profile.
                                Text(profile.visibleSlots.compactMap { $0?.label }
                                        .joined(separator: " · "))
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.42))
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if profile.id == store.selectedID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(profile.color)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(profile.id == store.selectedID
                                  ? profile.color.opacity(0.14)
                                  : Color.white.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                }

                Button("Reset this profile") { store.resetSelectedToFactory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Slot

private struct SlotCard: View {

    let widget: DashboardWidget?
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.05))

            if let widget {
                // Every card anchors its content to the top. The dock widgets
                // centre themselves, which is right in a short dock tile and
                // wrong in a tall grid cell — mixing the two made the row read
                // as content floating at random heights rather than as a grid.
                content(for: widget)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(7)
            } else {
                // An empty slot is a real state, not a bug — say so quietly
                // rather than leaving a blank rectangle.
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.15))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func content(for widget: DashboardWidget) -> some View {
        if let dock = widget.dockEquivalent {
            DockWidgetFactory.view(for: dock)
        } else {
            switch widget {
            case .events:      EventsCard(accent: accent)
            case .dayProgress: DayProgressCard(accent: accent)
            case .screenTime:  ScreenTimeCard(accent: accent)
            case .notes:       NotesCard()
            case .bluetooth:   BluetoothCard()
            case .quotes:      QuotesCard()
            default:           EmptyView()
            }
        }
    }
}

// MARK: - Cards the dock never had

/// Next few events from the calendar Mira already reads.
private struct EventsCard: View {
    let accent: Color
    @ObservedObject private var calendar = CalendarTodayService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CardTitle("Events", systemImage: "calendar", tint: accent)
            let today = calendar.eventsByDay[Calendar.current.startOfDay(for: Date())] ?? []
            let upcoming = today.filter { !$0.isAllDay && $0.endDate > Date() }.prefix(2)

            if upcoming.isEmpty {
                CardEmpty("Nothing left today")
            } else {
                ForEach(Array(upcoming), id: \.eventIdentifier) { event in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title ?? "Untitled")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                        Text(event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { calendar.requestAccess() }
    }
}

/// The same waking-hours fraction the Day Progress module plots, as one bar.
private struct DayProgressCard: View {
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle("Day", systemImage: "chart.bar.xaxis", tint: accent)
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let fraction = DayProgressModule.dayFraction
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule().fill(accent).frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Today's total from the tracker that has been running since launch.
private struct ScreenTimeCard: View {
    let accent: Color
    @ObservedObject private var service = ScreenTimeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CardTitle("Screen", systemImage: "hourglass", tint: accent)
            // Reuses the module's own formatter so the card and the Screen Time
            // panel can never disagree about the same number.
            Text(ScreenTimeModule.duration(service.totalSeconds))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
            if let top = service.ranked.first {
                Text(top.name)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Most recently edited note, from the same store the Notes module writes to —
/// a second copy of the text would immediately drift from it.
private struct NotesCard: View {
    @ObservedObject private var service = NotesService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CardTitle("Notes", systemImage: "note.text", tint: .white.opacity(0.5))
            if let note = service.notes.max(by: { $0.updatedAt < $1.updatedAt }),
               !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(note.body)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            } else {
                CardEmpty("No notes yet")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BluetoothCard: View {
    @ObservedObject private var service = BluetoothService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CardTitle("Bluetooth", systemImage: "wave.3.right", tint: .white.opacity(0.5))
            let connected = service.devices.filter(\.isConnected).prefix(2)
            if connected.isEmpty {
                CardEmpty("Nothing connected")
            } else {
                ForEach(Array(connected), id: \.id) { device in
                    HStack(spacing: 4) {
                        Text(device.name)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let battery = device.batteryPercent {
                            Text("\(battery)%")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Stable for the whole day rather than random per redraw — a quote that
/// reshuffles every time the panel opens is noise, not a quote.
private struct QuotesCard: View {
    private static let quotes = [
        "Make it work, then make it right.",
        "The best time to plant a tree was 20 years ago.",
        "Simplicity is the soul of efficiency.",
        "Slow is smooth, smooth is fast.",
        "You can't read the label from inside the jar.",
        "Done is better than perfect.",
        "What gets measured gets managed."
    ]

    private var todaysQuote: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return Self.quotes[day % Self.quotes.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "quote.opening")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
            Text(todaysQuote)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card chrome

private struct CardTitle: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 7))
                .foregroundColor(tint)
            Text(text.uppercased())
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
    }
}

private struct CardEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.white.opacity(0.28))
            .lineLimit(2)
    }
}
