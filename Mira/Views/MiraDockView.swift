import SwiftUI
import AppKit
import IOKit.ps
import CoreLocation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget registry
// ─────────────────────────────────────────────────────────────────────────────

enum DockWidgetType: String, CaseIterable, Identifiable {
    case clock, weather, nowPlaying, battery, appLauncher, pomodoro, toggles, soundMeter
    var id: String { rawValue }

    var label: String {
        switch self {
        case .clock:       "Clock"
        case .weather:     "Weather"
        case .nowPlaying:  "Now Playing"
        case .battery:     "Battery"
        case .appLauncher: "App Launcher"
        case .pomodoro:    "Pomodoro"
        case .toggles:     "Quick Toggles"
        case .soundMeter:  "Sound Meter"
        }
    }

    var icon: String {
        switch self {
        case .clock:       "clock"
        case .weather:     "cloud.sun"
        case .nowPlaying:  "music.note"
        case .battery:     "battery.75"
        case .appLauncher: "square.grid.2x2"
        case .pomodoro:    "timer"
        case .toggles:     "toggles"
        case .soundMeter:  "waveform"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget order persistence
// ─────────────────────────────────────────────────────────────────────────────

private let widgetOrderKey = "mira_dock_widget_order_v2"

private func loadWidgetOrder() -> [DockWidgetType] {
    guard let arr = UserDefaults.standard.stringArray(forKey: widgetOrderKey) else {
        return [.clock, .pomodoro, .nowPlaying, .battery, .toggles, .weather, .appLauncher]
    }
    return arr.compactMap { DockWidgetType(rawValue: $0) }
}

private func saveWidgetOrder(_ order: [DockWidgetType]) {
    UserDefaults.standard.set(order.map(\.rawValue), forKey: widgetOrderKey)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Main Dock View
// ─────────────────────────────────────────────────────────────────────────────

struct MiraDockView: View {
    @State private var widgets:   [DockWidgetType] = loadWidgetOrder()
    @State private var editMode   = false
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(widgets) { wtype in
                WidgetSlot(
                    wtype:    wtype,
                    editMode: editMode,
                    onRemove: { remove(wtype) }
                )
            }

            Button {
                showPicker.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 32, height: 60)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .top) {
                WidgetPickerPopover(active: widgets) { toggle($0) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.97))
                .shadow(color: .black.opacity(0.55), radius: 20, y: -4)
        )
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { editMode.toggle() }
            } label: {
                Label(editMode ? "Done Editing" : "Edit Dock",
                      systemImage: editMode ? "checkmark.circle" : "pencil.circle")
            }
            Divider()
            Button("Restore Defaults") {
                widgets = [.clock, .pomodoro, .nowPlaying, .battery, .toggles, .weather, .appLauncher]
                saveWidgetOrder(widgets)
            }
            Button("Hide Dock") { MiraDockManager.shared.hideDock() }
        }
    }

    private func remove(_ wtype: DockWidgetType) {
        withAnimation { widgets.removeAll { $0 == wtype } }
        saveWidgetOrder(widgets)
    }

    private func toggle(_ wtype: DockWidgetType) {
        if widgets.contains(wtype) { remove(wtype) }
        else { widgets.append(wtype); saveWidgetOrder(widgets) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget slot (card wrapper + popover + edit badge)
// ─────────────────────────────────────────────────────────────────────────────

private struct WidgetSlot: View {
    let wtype:    DockWidgetType
    let editMode: Bool
    let onRemove: () -> Void

    @State private var showDetail = false
    @ObservedObject private var pom = PomodoroService.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                if !editMode {
                    handleTap()
                }
            } label: {
                widgetContent
                    .frame(height: 58)
                    .background(cardBG)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetail, arrowEdge: .top) {
                detailContent
                    .padding(16)
                    .frame(minWidth: 260)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.11))
            }

            // Edit-mode remove badge
            if editMode {
                Button(action: onRemove) {
                    ZStack {
                        Circle().fill(Color.white).frame(width: 16, height: 16)
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.red)
                    }
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -8)
                .transition(.scale)
            }
        }
    }

    private var cardBG: some View {
        Group {
            if wtype == .pomodoro && pom.isRunning {
                LinearGradient(
                    colors: [Color(red: 0.0, green: 0.78, blue: 0.68),
                             Color(red: 0.0, green: 0.55, blue: 0.90)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            } else {
                Color.white.opacity(0.07)
            }
        }
    }

    private func handleTap() {
        switch wtype {
        case .clock:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        case .weather:
            if let url = URL(string: "weather://") {
                if !NSWorkspace.shared.open(url) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
                }
            }
        default:
            showDetail.toggle()
        }
    }

    @ViewBuilder
    private var widgetContent: some View {
        switch wtype {
        case .clock:       ClockWidget()
        case .weather:     WeatherWidget()
        case .nowPlaying:  NowPlayingWidget()
        case .battery:     BatteryWidget()
        case .appLauncher: AppLauncherWidget()
        case .pomodoro:    PomodoroWidget()
        case .toggles:     QuickTogglesWidget()
        case .soundMeter:  SoundMeterWidget()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch wtype {
        case .pomodoro:    PomodoroDetailPanel()
        case .weather:     WeatherDetailPanel()
        case .toggles:     TogglesDetailPanel()
        case .appLauncher: AppLauncherDetailPanel()
        case .nowPlaying:  NowPlayingDetailPanel()
        case .battery:     BatteryDetailPanel()
        default:           Text(wtype.label).foregroundColor(.white.opacity(0.5))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget picker
// ─────────────────────────────────────────────────────────────────────────────

private struct WidgetPickerPopover: View {
    let active:   [DockWidgetType]
    let onToggle: (DockWidgetType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Widgets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            Divider().opacity(0.1)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(DockWidgetType.allCases) { wtype in
                        let on = active.contains(wtype)
                        Button { onToggle(wtype) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: wtype.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(width: 22)
                                Text(wtype.label)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.blue) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(on ? Color.white.opacity(0.05) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 210, height: 270)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Clock
// ─────────────────────────────────────────────────────────────────────────────

private struct ClockWidget: View {
    @State private var now = Date()
    private let t = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(.white).monospacedDigit()
            Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .frame(width: 130)
        .onReceive(t) { now = $0 }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pomodoro
// ─────────────────────────────────────────────────────────────────────────────

private struct PomodoroWidget: View {
    @ObservedObject private var pom = PomodoroService.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeString)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white).monospacedDigit()
                Text(subLabel)
                    .font(.system(size: 10))
                    .foregroundColor(pom.isRunning ? .white.opacity(0.7) : .white.opacity(0.35))
            }
            HStack(spacing: 5) {
                Button { pom.isRunning ? pom.pause() : pom.start() } label: {
                    Image(systemName: pom.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(pom.isRunning ? 0.2 : 0.12)))
                }.buttonStyle(.plain)
                Button { pom.skip() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 200)
    }

    private var timeString: String { String(format: "%d:%02d", pom.secondsLeft/60, pom.secondsLeft%60) }
    private var subLabel: String {
        switch pom.phase {
        case .focus:      "Focus · \(pom.completed % pom.sessionsPerSet + 1)/\(pom.sessionsPerSet)"
        case .shortBreak: "Short Break"
        case .longBreak:  "Long Break"
        }
    }
}

private struct PomodoroDetailPanel: View {
    @ObservedObject private var pom = PomodoroService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pomodoro").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Reset") { pom.reset() }.font(.system(size: 11)).foregroundColor(.white.opacity(0.35)).buttonStyle(.plain)
            }
            ZStack {
                let total    = Double(pom.focusMins * 60)
                let progress = pom.phase == .focus ? (1 - Double(pom.secondsLeft) / max(1, total)) : 0
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(progress))
                    .stroke(Color(red: 0, green: 0.85, blue: 0.70), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: pom.secondsLeft)
                VStack(spacing: 1) {
                    Text(String(format: "%d:%02d", pom.secondsLeft/60, pom.secondsLeft%60))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white).monospacedDigit()
                    Text(phaseName).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }
            .frame(width: 120, height: 120).frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                ForEach(0..<pom.sessionsPerSet, id: \.self) { i in
                    Circle()
                        .fill(i < pom.completed % pom.sessionsPerSet
                              ? Color(red: 0, green: 0.85, blue: 0.70)
                              : Color.white.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
                Spacer()
                Text("\(pom.completed) done").font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
            }
            HStack {
                Text("Focus").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Stepper(value: Binding(get: { pom.focusMins }, set: { pom.setFocusMins($0) }), in: 5...60, step: 5) {
                    Text("\(pom.focusMins) min").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }

    private var phaseName: String {
        switch pom.phase { case .focus: "Focus"; case .shortBreak: "Short Break"; case .longBreak: "Long Break" }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Battery
// ─────────────────────────────────────────────────────────────────────────────

private struct BatteryWidget: View {
    @State private var pct = 100; @State private var charging = false
    private let t = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(pct)/100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90)).animation(.easeInOut(duration: 0.6), value: pct)
            VStack(spacing: 0) {
                Text("\(pct)").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundColor(.white)
                if charging { Image(systemName: "bolt.fill").font(.system(size: 7)).foregroundColor(.yellow) }
            }
        }
        .frame(width: 48, height: 48).frame(width: 68)
        .onAppear { read() }.onReceive(t) { _ in read() }
    }

    private var ringColor: Color {
        charging ? .green : pct <= 20 ? .red : pct <= 40 ? .orange : Color(red: 0.2, green: 0.9, blue: 0.4)
    }

    private func read() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
              let src  = list.first,
              let info = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any]
        else { return }
        pct      = info[kIOPSCurrentCapacityKey] as? Int ?? pct
        charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
    }
}

private struct BatteryDetailPanel: View {
    @State private var pct = 100; @State private var charging = false
    var body: some View {
        VStack(spacing: 8) {
            Text("Battery").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            Text("\(pct)%").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundColor(.white)
            Text(charging ? "Charging" : "On Battery").font(.system(size: 12)).foregroundColor(.white.opacity(0.4))
        }
        .onAppear {
            guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
                  let src  = list.first,
                  let info = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any]
            else { return }
            pct      = info[kIOPSCurrentCapacityKey] as? Int ?? pct
            charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Weather (auto-detects location via wttr.in IP)
// ─────────────────────────────────────────────────────────────────────────────

private struct WeatherWidget: View {
    @StateObject private var svc = WeatherService()
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: svc.weather.sfSymbol).font(.system(size: 18)).foregroundColor(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(svc.isLoaded ? "\(svc.weather.tempF)°" : "--")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundColor(.white)
                Text(svc.isLoaded ? svc.weather.location : "—")
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.4)).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).frame(width: 114)
        .onAppear { svc.fetch() }
    }
}

private struct WeatherDetailPanel: View {
    @StateObject private var svc = WeatherService()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: svc.weather.sfSymbol).font(.system(size: 36)).foregroundColor(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(svc.weather.tempF)°F")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    Text(svc.weather.condition).font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                    Text(svc.weather.location).font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("H \(svc.weather.highF)°").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                    Text("L \(svc.weather.lowF)°").font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                }
            }
            Button("Open Weather App") {
                if let u = URL(string: "weather://") { _ = NSWorkspace.shared.open(u) }
            }
            .font(.system(size: 11)).foregroundColor(.blue).buttonStyle(.plain)
        }
        .onAppear { svc.fetch() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Now Playing (Spotify via MediaRemote)
// ─────────────────────────────────────────────────────────────────────────────

private struct NowPlayingWidget: View {
    @ObservedObject private var np = NowPlayingService.shared

    var body: some View {
        HStack(spacing: 8) {
            artView.frame(width: 40, height: 40)
            if np.info.hasContent {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.info.title).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white).lineLimit(1)
                    Text(np.info.artist).font(.system(size: 10)).foregroundColor(.white.opacity(0.5)).lineLimit(1)
                }
                .frame(width: 86, alignment: .leading)
                controls
            } else {
                Text("Nothing playing").font(.system(size: 10)).foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 10).frame(minWidth: 200, maxWidth: 240)
        .onAppear { NowPlayingService.shared.start() }
    }

    private var artView: some View {
        Group {
            if let art = np.info.artwork {
                Image(nsImage: art).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08))
                    .overlay(Image(systemName: "music.note").font(.system(size: 14)).foregroundColor(.white.opacity(0.2)))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            btn("backward.fill", size: 11)  { np.previousTrack() }
            btn(np.info.isPlaying ? "pause.fill" : "play.fill", size: 14) { np.togglePlayPause() }
            btn("forward.fill",  size: 11)  { np.nextTrack() }
        }
    }

    private func btn(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundColor(.white.opacity(size > 12 ? 1 : 0.6))
        }.buttonStyle(.plain)
    }
}

private struct NowPlayingDetailPanel: View {
    @ObservedObject private var np = NowPlayingService.shared
    var body: some View {
        HStack(spacing: 14) {
            if let art = np.info.artwork {
                Image(nsImage: art).resizable().scaledToFill()
                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(np.info.title.isEmpty ? "Nothing Playing" : np.info.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                Text(np.info.artist).font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                HStack(spacing: 14) {
                    Button { np.previousTrack() } label: { Image(systemName: "backward.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.6)) }.buttonStyle(.plain)
                    Button { np.togglePlayPause() } label: { Image(systemName: np.info.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).foregroundColor(.white) }.buttonStyle(.plain)
                    Button { np.nextTrack() }      label: { Image(systemName: "forward.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.6)) }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { NowPlayingService.shared.start() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App Launcher (full /Applications bubble)
// ─────────────────────────────────────────────────────────────────────────────

private struct AppLauncherWidget: View {
    @State private var apps: [(id: String, icon: NSImage?)] = []

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(24)), GridItem(.fixed(24))], spacing: 4) {
            ForEach(pinnedApps().prefix(4), id: \.self) { bID in
                let icon = apps.first(where: { $0.id == bID })?.icon
                Button { launch(bID) } label: {
                    Group {
                        if let ic = icon { Image(nsImage: ic).resizable().scaledToFit() }
                        else { Image(systemName: "app").font(.system(size: 14)).foregroundColor(.white.opacity(0.3)) }
                    }
                    .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
        }
        .padding(8).frame(width: 84)
        .onAppear { loadPinned() }
    }

    private func loadPinned() {
        apps = pinnedApps().map { id in
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path ?? ""
            let icon = NSWorkspace.shared.icon(forFile: path)
            return (id: id, icon: icon.isValid ? icon : nil)
        }
    }

    private func launch(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

private func pinnedApps() -> [String] {
    UserDefaults.standard.stringArray(forKey: "mira_dock_pinned_apps")
        ?? ["com.apple.Safari", "com.apple.Music", "com.apple.Notes", "com.apple.finder"]
}

// Full app launcher panel — all installed apps with search
private struct AppLauncherDetailPanel: View {
    @State private var allApps: [(name: String, url: URL, icon: NSImage?)] = []
    @State private var query = ""

    private var filtered: [(name: String, url: URL, icon: NSImage?)] {
        query.isEmpty ? allApps : allApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
                TextField("Search apps…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.25)) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 80))], spacing: 10) {
                    ForEach(filtered, id: \.url) { app in
                        Button {
                            NSWorkspace.shared.openApplication(at: app.url, configuration: .init(), completionHandler: nil)
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let ic = app.icon { Image(nsImage: ic).resizable().scaledToFit() }
                                    else { Image(systemName: "app").font(.system(size: 24)).foregroundColor(.white.opacity(0.3)) }
                                }
                                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(app.name).font(.system(size: 9)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(width: 320, height: 340)
        .onAppear { loadApps() }
    }

    private func loadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm  = FileManager.default
            let dirs: [URL] = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
            ]
            var apps: [(name: String, url: URL, icon: NSImage?)] = []
            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for url in items where url.pathExtension == "app" {
                    let name = url.deletingPathExtension().lastPathComponent
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    apps.append((name: name, url: url, icon: icon.isValid ? icon : nil))
                }
            }
            let sorted = apps.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self.allApps = sorted }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quick Toggles (WiFi + DND moon)
// ─────────────────────────────────────────────────────────────────────────────

private struct QuickTogglesWidget: View {
    @AppStorage("mira_wifi_on")  private var wifiOn  = true
    @AppStorage("mira_dnd_on")   private var dndOn   = false
    @AppStorage("mira_bt_on")    private var btOn    = true

    var body: some View {
        HStack(spacing: 5) {
            circle("wifi",             color: .blue,   on: wifiOn)  { toggleWifi()  }
            circle("moon.zzz.fill",    color: .indigo, on: dndOn)   { toggleDND()   }
            circle("bluetooth",        color: .blue,   on: btOn)    { toggleBT()    }
        }
        .padding(.horizontal, 8).frame(width: 110)
    }

    private func circle(_ icon: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(on ? .white : .white.opacity(0.3))
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? color : Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private func toggleWifi() {
        wifiOn.toggle()
        shell("networksetup -setairportpower en0 \(wifiOn ? "on" : "off")")
    }

    private func toggleDND() {
        dndOn.toggle()
        // macOS 13+ Focus DND via defaults
        shell("defaults -currentHost write com.apple.notificationcenterui dndEnabledDisplaySleep -bool \(dndOn)")
        shell("defaults -currentHost write com.apple.notificationcenterui dndMirroring -bool \(dndOn)")
        shell("killall NotificationCenter 2>/dev/null; true")
    }

    private func toggleBT() {
        btOn.toggle()
        shell("blueutil --power \(btOn ? 1 : 0) 2>/dev/null || true")
    }
}

private struct TogglesDetailPanel: View {
    @AppStorage("mira_wifi_on") private var wifiOn = true
    @AppStorage("mira_dnd_on")  private var dndOn  = false
    @AppStorage("mira_bt_on")   private var btOn   = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Toggles").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
            row("Wi-Fi",          icon: "wifi",          color: .blue,   on: $wifiOn) { shell("networksetup -setairportpower en0 \(wifiOn ? "on" : "off")") }
            row("Do Not Disturb", icon: "moon.zzz.fill", color: .indigo, on: $dndOn) {
                shell("defaults -currentHost write com.apple.notificationcenterui dndEnabledDisplaySleep -bool \(dndOn)")
                shell("killall NotificationCenter 2>/dev/null; true")
            }
            row("Bluetooth",      icon: "bluetooth",     color: .blue,   on: $btOn)  { shell("blueutil --power \(btOn ? 1 : 0) 2>/dev/null || true") }
            row("Dark Mode",      icon: "moon.fill",     color: .purple,
                on: Binding(get: { isDark() }, set: { _ in toggleDark() })) { }
        }
    }

    private func row(_ label: String, icon: String, color: Color, on: Binding<Bool>, onToggle: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(.white.opacity(0.6)).frame(width: 24)
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).tint(color).labelsHidden()
                .onChange(of: on.wrappedValue) { _, _ in onToggle() }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func isDark() -> Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    private func toggleDark() { shell("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'") }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sound Meter
// ─────────────────────────────────────────────────────────────────────────────

private struct SoundMeterWidget: View {
    @ObservedObject private var np = NowPlayingService.shared
    @State private var levels: [CGFloat] = Array(repeating: 0.25, count: 8)
    @State private var animTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(levels[i]))
                    .frame(width: 4, height: max(4, levels[i] * 40))
                    .animation(.easeInOut(duration: 0.14), value: levels[i])
            }
        }
        .frame(width: 62)
        .onAppear  { startAnim() }
        .onDisappear { animTask?.cancel() }
    }

    private func barColor(_ h: CGFloat) -> Color {
        Color(red: 0.15, green: Double(0.7 + h * 0.25), blue: 0.4)
    }

    private func startAnim() {
        animTask = Task {
            while !Task.isCancelled {
                let playing = await MainActor.run { np.info.isPlaying }
                await MainActor.run {
                    levels = (0..<8).map { _ in
                        playing ? CGFloat.random(in: 0.12...1.0) : max(0.05, levels[Int.random(in: 0..<8)] * 0.55)
                    }
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shell helper
// ─────────────────────────────────────────────────────────────────────────────

@discardableResult
private func shell(_ cmd: String) -> Int32 {
    let p = Process(); p.launchPath = "/bin/zsh"; p.arguments = ["-c", cmd]
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}

private func isDark() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
}
