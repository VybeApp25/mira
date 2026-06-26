import SwiftUI
import AppKit
import IOKit.ps

// ── Pinned apps stored as bundle IDs ─────────────────────────────────────────

private let pinnedAppsKey = "mira_dock_pinned_apps"

private func defaultPinnedApps() -> [String] {
    ["com.apple.Safari", "com.apple.Music",
     "com.apple.Notes", "com.apple.finder"]
}

// MARK: - Main Dock View

struct MiraDockView: View {
    var body: some View {
        ZStack {
            // Outer pill background
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.92))
                .shadow(color: .black.opacity(0.5), radius: 20, y: -4)

            HStack(spacing: 8) {
                ClockCard()
                Divider().frame(height: 60).opacity(0.12)
                WeatherDockCard()
                Divider().frame(height: 60).opacity(0.12)
                AppLauncherCard()
                Divider().frame(height: 60).opacity(0.12)
                BatteryRingCard()
                Divider().frame(height: 60).opacity(0.12)
                NowPlayingCard()
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 90)
    }
}

// MARK: - Card wrapper

private struct DockCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
            content
        }
    }
}

// MARK: - Clock Card

private struct ClockCard: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        DockCard {
            VStack(alignment: .leading, spacing: 3) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 158)
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - Weather Card

private struct WeatherDockCard: View {
    @State private var weather: WeatherSnapshot?
    @State private var task: Task<Void, Never>?

    var body: some View {
        DockCard {
            if let w = weather {
                HStack(spacing: 12) {
                    // Current
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.tempString)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Text("Today")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    // 3-day forecast
                    HStack(spacing: 10) {
                        ForEach(w.forecast.prefix(3), id: \.day) { day in
                            VStack(spacing: 3) {
                                Text(day.day)
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.45))
                                Text(day.icon)
                                    .font(.system(size: 15))
                                Text(day.tempString)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            } else {
                ProgressView().tint(.white).scaleEffect(0.6)
            }
        }
        .frame(width: 200)
        .onAppear { fetchWeather() }
    }

    private func fetchWeather() {
        task?.cancel()
        task = Task {
            guard let url = URL(string: "https://wttr.in/?format=j1") else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = (json["current_condition"] as? [[String: Any]])?.first,
                  let tempC = (current["temp_C"] as? [String])?.first ?? current["temp_C"] as? String,
                  let weather = (json["weather"] as? [[String: Any]])
            else { return }

            let forecast = weather.prefix(3).compactMap { day -> DayForecast? in
                guard let dateStr  = day["date"] as? String,
                      let maxTempC = (day["maxtempC"] as? [String])?.first ?? day["maxtempC"] as? String,
                      let hourly   = (day["hourly"] as? [[String: Any]])?.first,
                      let descArr  = hourly["weatherDesc"] as? [[String: String]],
                      let desc     = descArr.first?["value"]
                else { return nil }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let date = formatter.date(from: dateStr) ?? Date()
                let dayName = Calendar.current.isDateInToday(date) ? "Today"
                    : date.formatted(.dateTime.weekday(.abbreviated))

                return DayForecast(
                    day: String(dayName.prefix(3)),
                    icon: weatherEmoji(desc),
                    tempString: "\(maxTempC)°"
                )
            }

            await MainActor.run {
                self.weather = WeatherSnapshot(tempString: "\(tempC)°", forecast: Array(forecast))
            }
        }
    }

    private struct WeatherSnapshot {
        var tempString: String
        var forecast: [DayForecast]
    }

    private struct DayForecast {
        var day: String
        var icon: String
        var tempString: String
    }

    private func weatherEmoji(_ desc: String) -> String {
        let d = desc.lowercased()
        if d.contains("sun") || d.contains("clear")    { return "☀️" }
        if d.contains("partly") || d.contains("cloud") { return "⛅" }
        if d.contains("overcast")                       { return "☁️" }
        if d.contains("rain") || d.contains("drizzle") { return "🌧️" }
        if d.contains("thunder")                        { return "⛈️" }
        if d.contains("snow")                           { return "❄️" }
        if d.contains("fog") || d.contains("mist")     { return "🌫️" }
        return "🌡️"
    }
}

// MARK: - App Launcher Card

private struct AppLauncherCard: View {
    @State private var apps: [(id: String, icon: NSImage?)] = []
    private let udKey = "mira_dock_pinned_apps"

    var body: some View {
        DockCard {
            let grid = Array(apps.prefix(4))
            LazyVGrid(columns: [GridItem(.fixed(34)), GridItem(.fixed(34))], spacing: 4) {
                ForEach(grid, id: \.id) { app in
                    Button { launch(app.id) } label: {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 104)
        .onAppear { loadApps() }
    }

    private func loadApps() {
        let ids = UserDefaults.standard.stringArray(forKey: udKey) ?? defaultPinnedApps()
        apps = ids.map { id in
            let icon = NSWorkspace.shared.icon(forFile: appPath(id) ?? "")
            return (id: id, icon: icon.isValid ? icon : nil)
        }
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    private func appPath(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }
}

// MARK: - Battery Ring Card

private struct BatteryRingCard: View {
    @State private var percent: Int = 100
    @State private var charging: Bool = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        DockCard {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: percent)
                VStack(spacing: 1) {
                    Text("\(percent)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                    }
                }
            }
            .frame(width: 60, height: 60)
            .padding(10)
        }
        .frame(width: 80)
        .onAppear { updateBattery() }
        .onReceive(timer) { _ in updateBattery() }
    }

    private var ringColor: Color {
        if charging { return .green }
        if percent <= 20 { return .red }
        if percent <= 40 { return .orange }
        return Color(red: 0.2, green: 0.9, blue: 0.4)
    }

    private func updateBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let src  = list.first,
              let info = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any]
        else { return }
        percent  = info[kIOPSCurrentCapacityKey] as? Int ?? percent
        charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    }
}

// MARK: - Now Playing Card

private struct NowPlayingCard: View {
    @ObservedObject private var np = NowPlayingService.shared

    var body: some View {
        DockCard {
            if np.info.hasContent {
                HStack(spacing: 10) {
                    // Artwork
                    if let art = np.info.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 52, height: 52)
                            .overlay(Image(systemName: "music.note").foregroundColor(.white.opacity(0.3)))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(np.info.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(np.info.artist)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)

                        // Controls
                        HStack(spacing: 16) {
                            Button { np.previousTrack() } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)

                            Button { np.togglePlayPause() } label: {
                                Image(systemName: np.info.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            Button { np.nextTrack() } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.2))
                    Text("Nothing playing")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(minWidth: 260)
    }
}
