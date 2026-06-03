import SwiftUI
import EventKit

// MARK: - Shared card style

private let cardBG = Color(red: 0.11, green: 0.11, blue: 0.14)
private let cardR: CGFloat = 16
private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

// MARK: - Home tab — three side-by-side cards

struct HomeTabView: View {
    @ObservedObject var miraState: MiraState

    @StateObject private var nowPlaying = NowPlayingService()
    @StateObject private var weather    = WeatherService()

    var body: some View {
        HStack(spacing: 8) {
            NowPlayingCard(service: nowPlaying)
            WeatherCard(service: weather)
            CalendarCard()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear  { nowPlaying.start(); weather.fetch() }
        .onDisappear { nowPlaying.stop() }
    }
}

// MARK: - Now Playing

private struct NowPlayingCard: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        CardShell {
            if service.info.hasContent {
                VStack(alignment: .leading, spacing: 0) {
                    artworkView
                    Spacer(minLength: 8)
                    trackInfo
                    Spacer(minLength: 10)
                    controls
                }
                .padding(12)
            } else {
                idleState
            }
        }
    }

    private var artworkView: some View {
        Group {
            if let img = service.info.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.07)
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.20))
                }
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(service.info.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if !service.info.artist.isEmpty {
                Text(service.info.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.42))
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ctrlBtn("backward.fill", size: 12) { service.previousTrack() }
            ctrlBtn(service.info.isPlaying ? "pause.fill" : "play.fill", size: 14) { service.togglePlayPause() }
            ctrlBtn("forward.fill",  size: 12) { service.nextTrack() }
        }
    }

    private func ctrlBtn(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var idleState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.12))
            Text("Nothing Playing")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Weather

private struct WeatherCard: View {
    @ObservedObject var service: WeatherService

    var body: some View {
        CardShell {
            if service.isLoaded {
                VStack(alignment: .leading, spacing: 0) {
                    // Icon + condition row
                    HStack(spacing: 6) {
                        Image(systemName: service.weather.sfSymbol)
                            .font(.system(size: 20))
                            .foregroundColor(iconTint)
                            .symbolRenderingMode(.multicolor)
                        Text(service.weather.condition)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    // Big temperature
                    Text("\(service.weather.tempF)°F")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer(minLength: 4)

                    // Hi / Lo
                    HStack(spacing: 6) {
                        Label("\(service.weather.highF)°", systemImage: "arrow.up")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.40))
                        Label("\(service.weather.lowF)°", systemImage: "arrow.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.40))
                    }

                    Spacer(minLength: 8)

                    // Location
                    if !service.weather.location.isEmpty {
                        Label(service.weather.location, systemImage: "location.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.10))
                    Text("Loading weather…")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.22))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var iconTint: Color {
        switch service.weather.sfSymbol {
        case let s where s.contains("sun"):   return Color(red: 1.0,  green: 0.80, blue: 0.20)
        case let s where s.contains("rain"):  return Color(red: 0.40, green: 0.70, blue: 1.0)
        case let s where s.contains("snow"):  return Color(red: 0.80, green: 0.92, blue: 1.0)
        case let s where s.contains("bolt"):  return Color(red: 1.0,  green: 0.88, blue: 0.20)
        default:                               return Color(red: 0.75, green: 0.82, blue: 0.95)
        }
    }
}

// MARK: - Calendar

private struct CalendarCard: View {
    @State private var events:    [EKEvent] = []
    @State private var permitted: Bool      = false
    @State private var checked:   Bool      = false

    private let store = EKEventStore()
    private let today = Date()

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: 0) {
                dateHeader
                Divider()
                    .background(Color.white.opacity(0.07))
                    .padding(.vertical, 8)
                eventsSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .onAppear(perform: requestAccess)
    }

    // "TUE" above, big day number, month below
    private var dateHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(today.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(accent)
                Text(today.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            Text(today.formatted(.dateTime.day()))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !permitted && checked {
            Text("Enable calendar in System Settings")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
        } else if events.isEmpty && checked {
            Label("No events today", systemImage: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events.prefix(2), id: \.eventIdentifier) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Calendar colour dot
            Circle()
                .fill(event.calendar.cgColor.map { Color($0) } ?? accent)
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Text(event.isAllDay ? "All day" : event.startDate.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.32))
            }
        }
    }

    private func requestAccess() {
        // Always check current status first — never show the dialog twice.
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:                           // pre-macOS 14 grant
            permitted = true; checked = true; load(); return
        case .denied, .restricted:
            permitted = false; checked = true; return
        default: break   // .notDetermined or .fullAccess (macOS 14) — fall through to request
        }
        if #available(macOS 14.0, *), status.rawValue == 3 {  // .fullAccess = 3
            permitted = true; checked = true; load(); return
        }
        // Only reaches here when status is .notDetermined — show dialog once
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in
                DispatchQueue.main.async { self.permitted = ok; self.checked = true; if ok { self.load() } }
            }
        } else {
            store.requestAccess(to: .event) { ok, _ in
                DispatchQueue.main.async { self.permitted = ok; self.checked = true; if ok { self.load() } }
            }
        }
    }

    private func load() {
        let cal   = Calendar.current
        let start = cal.startOfDay(for: today)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let pred  = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events    = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }
}

// MARK: - Card shell

private struct CardShell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cardR, style: .continuous)
                .fill(cardBG)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - CGColor → SwiftUI Color

private extension Color {
    init?(_ cg: CGColor) {
        guard let ns = NSColor(cgColor: cg) else { return nil }
        self = Color(ns)
    }
}
