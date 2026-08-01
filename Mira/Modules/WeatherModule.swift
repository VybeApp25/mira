// WeatherModule.swift
// The first NotchModule conformer. See docs/specs/macnotch-parity-audit.md.
//
// First pass of this looked wrong, and the reasons are worth recording so the
// next module doesn't repeat them:
//
//   • The atmosphere was a hard-edged rectangle inset in the black slab, with
//     black bars above and below. It read as a card pasted into a panel. The sky
//     must fill the module edge to edge and run UNDER the header.
//   • Six fields of data in a 700pt-wide panel left the right half empty, and
//     empty reads as broken. Density is not decoration here — it is the design.
//   • The gradient was muddy navy regardless of conditions, so "Sunny, 91°"
//     looked like dusk in a storm. Sky color has to track condition AND daylight.
//
// The data was available the whole time: wttr.in's j1 payload already carries
// feels-like, humidity, UV, wind, pressure, cloud cover, sunrise/sunset, 3 days,
// and 8 three-hourly points per day. WeatherService was parsing six of them.
// No new request, no API key, no entitlement.
//
// Still ahead: the procedural sky renderer replaces `SkyBackdrop` (cloudCover
// drives density, windMph drives rain angle — both already parsed), and a
// WeatherKit provider would extend the 3-day row to 10.

import SwiftUI
import Combine

@MainActor
final class WeatherModule: NotchModule, ObservableObject {

    let id    = "weather"
    let title = "Weather"

    var icon: String {
        service.isLoaded ? service.weather.sfSymbol : "cloud.sun.fill"
    }

    /// Current conditions + detail chips + the hourly strip fill `.compact`
    /// exactly. At `.standard` there was ~100pt of empty sky between the temp
    /// block and the strip, and a panel taller than its content reads as unfinished.
    /// Tall mode steps up to `.standard` and spends that room on the multi-day row.
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

    let service = WeatherService()
    private var cancellables = Set<AnyCancellable>()

    /// Matches MacNotch's stated cadence ("Weather refreshes every 10 min").
    private static let refreshInterval: TimeInterval = 600
    private var refreshTimer: Timer?

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() { service.fetch() }

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

    func makeContent() -> AnyView {
        AnyView(WeatherModuleView(service: service,
                                  showsDailyRow: resolvedHeightLevel == .tall))
    }
}

// MARK: - View

private struct WeatherModuleView: View {

    @ObservedObject var service: WeatherService
    let showsDailyRow: Bool

    private var w: WeatherInfo { service.weather }

    var body: some View {
        ZStack {
            // Edge to edge, behind everything. `ignoresSafeArea` is not enough —
            // the shell clips content, so the backdrop is simply the bottom layer
            // of a ZStack that fills the module's whole area.
            SkyBackdrop(symbol: w.sfSymbol, cloudCover: w.cloudCover)
                .allowsHitTesting(false)

            if service.isLoaded {
                content
            } else {
                ProgressView().controlSize(.small).tint(.white.opacity(0.55))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                currentBlock
                Spacer(minLength: 8)
                detailGrid
            }
            .padding(.horizontal, 18)
            // Clear the shell's overlaid header; the sky behind still runs full height.
            .padding(.top, NotchModuleShellView.headerHeight + 4)

            Spacer(minLength: 6)

            if showsDailyRow, !service.daily.isEmpty {
                dailyRow
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            if !service.hourly.isEmpty {
                hourlyStrip
            }
        }
    }

    // MARK: - Current

    private var currentBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 1) {
                Text(w.tempF)
                    .font(.system(size: 52, weight: .ultraLight))
                    .foregroundColor(.white)
                Text("°")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.top, 6)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)

            Text(w.condition)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)

            HStack(spacing: 8) {
                Text("H:\(w.highF)°")
                Text("L:\(w.lowF)°")
                Text("Feels \(w.feelsLikeF)°")
                    .foregroundColor(.white.opacity(0.55))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(w.tempF) degrees, \(w.condition), high \(w.highF), low \(w.lowF), feels like \(w.feelsLikeF)")
    }

    // MARK: - Detail chips

    /// The metrics that fill the right half — the space that read as dead before.
    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                metric("humidity", "Humidity", "\(w.humidity)%")
                metric("wind", "Wind", "\(w.windMph) mph \(w.windDir)")
            }
            GridRow {
                metric("sun.max", "UV", w.uvIndex)
                metric("drop", "Precip", "\(w.precipIn)\"")
            }
            GridRow {
                metric("sunrise", "Sunrise", w.sunrise)
                metric("sunset", "Sunset", w.sunset)
            }
        }
        .padding(.top, 2)
    }

    private func metric(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: -1) {
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.40))
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Hourly strip

    /// Anchored to the bottom edge on a darkened band, so the panel has a base
    /// instead of trailing off into empty gradient.
    private var hourlyStrip: some View {
        HStack(spacing: 0) {
            ForEach(service.hourly) { hour in
                VStack(spacing: 3) {
                    Text(hour.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                    Image(systemName: hour.symbol)
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.white.opacity(0.92))
                    Text("\(hour.tempF)°")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    // Only draw the rain chance when it's meaningful — a row of
                    // "0%" under every hour is noise that buries the real signal.
                    Text(hour.rainPct >= 20 ? "\(hour.rainPct)%" : " ")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(hour.label), \(hour.tempF) degrees, \(hour.rainPct) percent chance of rain")
            }
        }
        .padding(.vertical, 6)
        // Keep the last column clear of the shell's collapse button, which sits
        // in the bottom-right corner on every module.
        .padding(.trailing, 26)
        .background(
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.28)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Daily row (tall mode)

    private var dailyRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(service.daily.enumerated()), id: \.element.id) { idx, day in
                HStack(spacing: 7) {
                    Text(idx == 0 ? "Today" : day.weekdayLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.70))
                        .frame(width: 42, alignment: .leading)
                    Image(systemName: day.symbol)
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.white.opacity(0.90))
                    Text("\(day.highF)°")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text("\(day.lowF)°")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Sky

/// Placeholder atmosphere: a condition- and daylight-aware gradient plus a soft
/// light source. This is the single seam the procedural renderer replaces —
/// nothing else in the module needs to change when it does.
private struct SkyBackdrop: View {
    let symbol: String
    let cloudCover: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .top, endPoint: .bottom)

            // Off-center glow so the sky has a light source rather than reading
            // as a flat fill. Dimmed as cloud cover rises.
            RadialGradient(
                colors: [glowColor.opacity(0.55 * (1 - Double(cloudCover) / 140.0)), .clear],
                center: UnitPoint(x: 0.74, y: 0.16),
                startRadius: 4,
                endRadius: 210
            )
        }
    }

    private var isNight: Bool { symbol.contains("moon") || symbol.contains("stars") }

    private var glowColor: Color {
        if isNight { return Color(red: 0.62, green: 0.68, blue: 0.95) }
        if symbol.contains("sun") || symbol.contains("clear") {
            return Color(red: 1.0, green: 0.92, blue: 0.66)
        }
        return Color(red: 0.85, green: 0.90, blue: 1.0)
    }

    /// Brighter and more saturated than the first attempt — a sunny 91° day
    /// should not render as a storm at dusk.
    private var palette: [Color] {
        switch symbol {
        case let s where s.contains("snow"):
            return [Color(red: 0.62, green: 0.70, blue: 0.80), Color(red: 0.30, green: 0.36, blue: 0.45)]
        case let s where s.contains("bolt"):
            return [Color(red: 0.29, green: 0.28, blue: 0.42), Color(red: 0.12, green: 0.12, blue: 0.20)]
        case let s where s.contains("rain") || s.contains("drizzle") || s.contains("sleet"):
            return [Color(red: 0.33, green: 0.44, blue: 0.56), Color(red: 0.15, green: 0.21, blue: 0.29)]
        case let s where s.contains("fog"):
            return [Color(red: 0.52, green: 0.55, blue: 0.58), Color(red: 0.26, green: 0.28, blue: 0.31)]
        case let s where s.contains("moon") || s.contains("stars"):
            return [Color(red: 0.10, green: 0.13, blue: 0.28), Color(red: 0.03, green: 0.04, blue: 0.11)]
        case let s where s.contains("cloud.sun"):
            return [Color(red: 0.36, green: 0.58, blue: 0.80), Color(red: 0.17, green: 0.29, blue: 0.45)]
        case let s where s.contains("cloud"):
            return [Color(red: 0.42, green: 0.50, blue: 0.60), Color(red: 0.20, green: 0.25, blue: 0.33)]
        default:   // clear day
            return [Color(red: 0.26, green: 0.58, blue: 0.88), Color(red: 0.10, green: 0.28, blue: 0.52)]
        }
    }
}
