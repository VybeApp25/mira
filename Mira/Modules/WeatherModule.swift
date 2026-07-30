// WeatherModule.swift
// The first NotchModule conformer, and the proof that the Phase 0 shell contract
// actually holds. See docs/specs/macnotch-parity-audit.md.
//
// Deliberately built in layers so the expensive parts can land independently:
//
//   1. THIS FILE — the module, on top of the existing wttr.in WeatherService.
//      Current conditions only, because that is genuinely all WeatherService
//      parses (temp, condition, symbol, city, high, low — six fields).
//   2. NEXT — a WeatherKit-backed provider supplying hourly, 7-day, and the
//      detail chips (feels-like / humidity / precip / pressure / UV / wind).
//      Blocked on the WeatherKit capability being enabled for the App ID, which
//      is a developer-portal step, not a code step.
//   3. NEXT — the procedural sky renderer (SwiftUI/Metal) behind the content,
//      driven by the same data so wind speed can drive rain angle and cloud
//      cover can drive density.
//
// The tall-mode toggle is already declared here even though there is nothing
// taller to show yet: it is what the 7-day forecast row will occupy, and
// declaring it now means the Settings surface and the height plumbing get
// exercised by a real module rather than by a stub.

import SwiftUI
import Combine

@MainActor
final class WeatherModule: NotchModule, ObservableObject {

    let id    = "weather"
    let title = "Weather"

    /// Tracks the current condition so the dock/carousel glyph reflects reality
    /// rather than sitting on a generic cloud forever.
    var icon: String {
        service.isLoaded ? service.weather.sfSymbol : "cloud.sun.fill"
    }

    /// Current conditions fit comfortably in the short panel. The 7-day row is
    /// what earns the step up to `.standard`, via the tall-mode toggle.
    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = true

    var subtitle: NotchHeaderSubtitle? {
        let city = service.weather.location
        guard !city.isEmpty else { return nil }
        return NotchHeaderSubtitle(text: city)
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [
            NotchHeaderAccessory(id: "refresh",
                                 systemImage: "arrow.clockwise",
                                 label: "Refresh weather") { [weak self] in
                self?.refresh()
            }
        ]
    }

    // MARK: - Data

    private let service = WeatherService()
    private var cancellables = Set<AnyCancellable>()

    /// MacNotch refreshes every 10 minutes ("Weather refreshes every 10 min");
    /// matching that is a sensible ceiling for a free tier and for battery.
    private static let refreshInterval: TimeInterval = 600
    private var refreshTimer: Timer?

    init() {
        // Re-publish the service's changes as our own so the shell re-renders
        // when a fetch lands. WeatherService is a separate ObservableObject, so
        // without this the view would never learn the data changed.
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() { service.fetch() }

    // MARK: - Lifecycle

    /// Polling starts when the module becomes visible and stops when it doesn't.
    /// A weather module refreshing every 10 minutes while nobody is looking at it
    /// is pure battery cost.
    func didAppear() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func didDisappear() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Content

    func makeContent() -> AnyView {
        AnyView(WeatherModuleView(service: service))
    }
}

// MARK: - View

private struct WeatherModuleView: View {

    @ObservedObject var service: WeatherService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        ZStack {
            // Placeholder atmosphere. This gradient is the seam the procedural
            // sky renderer replaces — it is intentionally the only thing behind
            // the content so swapping it in touches nothing else.
            skyGradient
                .allowsHitTesting(false)

            if service.isLoaded {
                loaded
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            }
        }
    }

    private var loaded: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(service.weather.tempF)
                        .font(.system(size: 40, weight: .thin))
                        .foregroundColor(.white)
                    Text("°")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundColor(.white.opacity(0.55))
                }
                Text(service.weather.condition)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label(service.weather.highF, systemImage: "arrow.up")
                    Label(service.weather.lowF, systemImage: "arrow.down")
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 0)

            Image(systemName: service.weather.sfSymbol)
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.white.opacity(0.92))
                .accessibilityHidden(true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(service.weather.tempF) degrees, \(service.weather.condition), "
            + "high \(service.weather.highF), low \(service.weather.lowF)"
        )
    }

    /// Condition-keyed gradient. A stand-in for the real sky, but keyed off the
    /// same SF Symbol the service already derives, so the mapping the procedural
    /// renderer needs is being exercised from day one.
    private var skyGradient: LinearGradient {
        let symbol = service.weather.sfSymbol
        let colors: [Color]
        switch symbol {
        case let s where s.contains("snow"):
            colors = [Color(red: 0.42, green: 0.50, blue: 0.60), Color(red: 0.20, green: 0.24, blue: 0.31)]
        case let s where s.contains("rain") || s.contains("drizzle"):
            colors = [Color(red: 0.24, green: 0.31, blue: 0.40), Color(red: 0.11, green: 0.15, blue: 0.21)]
        case let s where s.contains("bolt"):
            colors = [Color(red: 0.20, green: 0.19, blue: 0.30), Color(red: 0.09, green: 0.09, blue: 0.15)]
        case let s where s.contains("fog") || s.contains("haze"):
            colors = [Color(red: 0.38, green: 0.40, blue: 0.43), Color(red: 0.18, green: 0.19, blue: 0.21)]
        case let s where s.contains("cloud"):
            colors = [Color(red: 0.28, green: 0.34, blue: 0.42), Color(red: 0.13, green: 0.16, blue: 0.21)]
        case let s where s.contains("moon") || s.contains("stars"):
            colors = [Color(red: 0.09, green: 0.11, blue: 0.22), Color(red: 0.04, green: 0.05, blue: 0.10)]
        default:   // clear day
            colors = [Color(red: 0.19, green: 0.42, blue: 0.66), Color(red: 0.07, green: 0.15, blue: 0.27)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}
