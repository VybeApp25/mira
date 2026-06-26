import SwiftUI
import AppKit
import IOKit.ps

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget type registry
// ─────────────────────────────────────────────────────────────────────────────

enum DockWidgetType: String, CaseIterable, Identifiable {
    case clock       = "clock"
    case weather     = "weather"
    case nowPlaying  = "now_playing"
    case battery     = "battery"
    case appLauncher = "app_launcher"
    case pomodoro    = "pomodoro"
    case toggles     = "toggles"
    case soundMeter  = "sound_meter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clock:       return "Clock"
        case .weather:     return "Weather"
        case .nowPlaying:  return "Now Playing"
        case .battery:     return "Battery"
        case .appLauncher: return "App Launcher"
        case .pomodoro:    return "Pomodoro"
        case .toggles:     return "Quick Toggles"
        case .soundMeter:  return "Sound Meter"
        }
    }

    var icon: String {
        switch self {
        case .clock:       return "clock"
        case .weather:     return "cloud.sun"
        case .nowPlaying:  return "music.note"
        case .battery:     return "battery.75"
        case .appLauncher: return "square.grid.2x2"
        case .pomodoro:    return "timer"
        case .toggles:     return "toggles"
        case .soundMeter:  return "waveform"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget order persistence
// ─────────────────────────────────────────────────────────────────────────────

private let widgetOrderKey = "mira_dock_widget_order"

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
    @State private var widgets:     [DockWidgetType] = loadWidgetOrder()
    @State private var editMode     = false
    @State private var showPicker   = false
    @State private var expandedID:  DockWidgetType?   = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Expanded detail panel (appears above clicked widget)
            if let id = expandedID {
                expandedPanel(for: id)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // The bar itself
            bar
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.80), value: expandedID)
        .onTapGesture { }   // absorb clicks so the panel doesn't close on bar tap
        .background(
            Color.clear.contentShape(Rectangle())
                .onTapGesture { expandedID = nil }
        )
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 5) {
            ForEach(widgets) { wtype in
                widgetCard(wtype)
            }

            // Add button
            Button {
                showPicker.toggle()
                expandedID = nil
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 36, height: 56)
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
                .fill(Color(red: 0.06, green: 0.06, blue: 0.07).opacity(0.96))
                .shadow(color: .black.opacity(0.6), radius: 24, y: -6)
        )
        .contextMenu {
            Button { withAnimation { editMode.toggle() } } label: {
                Label(editMode ? "Done" : "Edit Dock", systemImage: editMode ? "checkmark" : "pencil")
            }
            Divider()
            Button("Restore Defaults") {
                widgets = [.clock, .pomodoro, .nowPlaying, .battery, .toggles, .weather, .appLauncher]
                saveWidgetOrder(widgets)
            }
        }
    }

    // MARK: Widget card wrapper

    @ViewBuilder
    private func widgetCard(_ wtype: DockWidgetType) -> some View {
        ZStack(alignment: .topLeading) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                    expandedID = expandedID == wtype ? nil : wtype
                }
            } label: {
                widgetContent(wtype)
                    .frame(height: 56)
                    .background(cardBackground(for: wtype))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            // Edit-mode remove button
            if editMode {
                Button {
                    withAnimation { remove(wtype) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .background(Circle().fill(Color.white).padding(2))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -8)
            }
        }
    }

    // MARK: Widget content router

    @ViewBuilder
    private func widgetContent(_ wtype: DockWidgetType) -> some View {
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

    // MARK: Card background

    private func cardBackground(for wtype: DockWidgetType) -> some View {
        Group {
            if wtype == .pomodoro, PomodoroService.shared.isRunning {
                LinearGradient(
                    colors: [Color(red: 0.0, green: 0.75, blue: 0.65),
                             Color(red: 0.0, green: 0.60, blue: 0.85)],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                )
            } else if expandedID == wtype {
                Color.white.opacity(0.10)
            } else {
                Color.white.opacity(0.06)
            }
        }
    }

    // MARK: Expanded detail panels

    @ViewBuilder
    private func expandedPanel(for wtype: DockWidgetType) -> some View {
        VStack(spacing: 0) {
            Group {
                switch wtype {
                case .pomodoro:   PomodoroDetailPanel()
                case .weather:    WeatherDetailPanel()
                case .toggles:    TogglesDetailPanel()
                case .appLauncher: AppLauncherDetailPanel()
                case .nowPlaying: NowPlayingDetailPanel()
                default:          EmptyView()
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.97))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
            )
        }
        .frame(maxWidth: 340)
        .padding(.bottom, 80)
        .padding(.leading, 10)
    }

    // MARK: Edit helpers

    private func remove(_ wtype: DockWidgetType) {
        widgets.removeAll { $0 == wtype }
        saveWidgetOrder(widgets)
        if expandedID == wtype { expandedID = nil }
    }

    private func toggle(_ wtype: DockWidgetType) {
        if widgets.contains(wtype) { remove(wtype) }
        else { widgets.append(wtype); saveWidgetOrder(widgets) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Widget picker popover
// ─────────────────────────────────────────────────────────────────────────────

private struct WidgetPickerPopover: View {
    let active: [DockWidgetType]
    let onToggle: (DockWidgetType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Widgets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider().opacity(0.1)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(DockWidgetType.allCases) { wtype in
                        let isOn = active.contains(wtype)
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
                                if isOn {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isOn ? Color.white.opacity(0.05) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 220, height: 280)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Clock Widget
// ─────────────────────────────────────────────────────────────────────────────

private struct ClockWidget: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .frame(width: 130)
        .onReceive(timer) { now = $0 }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pomodoro Widget + Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

private struct PomodoroWidget: View {
    @ObservedObject private var pom = PomodoroService.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeString)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(pom.isRunning ? .white : .white.opacity(0.85))
                    .monospacedDigit()
                Text(subLabel)
                    .font(.system(size: 10))
                    .foregroundColor(pom.isRunning ? .white.opacity(0.7) : .white.opacity(0.35))
            }

            HStack(spacing: 6) {
                Button {
                    pom.isRunning ? pom.pause() : pom.start()
                } label: {
                    Image(systemName: pom.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundColor(pom.isRunning ? .white : .white.opacity(0.7))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(pom.isRunning ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Button { pom.skip() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 200)
    }

    private var timeString: String {
        let m = pom.secondsLeft / 60
        let s = pom.secondsLeft % 60
        return String(format: "%d:%02d", m, s)
    }

    private var subLabel: String {
        switch pom.phase {
        case .focus:      return "Focus · \(pom.completed + 1)/\(pom.sessionsPerSet)"
        case .shortBreak: return "Short Break"
        case .longBreak:  return "Long Break"
        }
    }
}

private struct PomodoroDetailPanel: View {
    @ObservedObject private var pom = PomodoroService.shared
    @State private var focusMins = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pomodoro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Reset") { pom.reset() }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .buttonStyle(.plain)
            }

            // Progress ring
            ZStack {
                let total = Double(pom.focusMins * 60)
                let remaining = Double(pom.secondsLeft)
                let progress = pom.phase == .focus ? (1 - remaining / total) : (1 - remaining / max(1, total))

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(Color(red: 0.0, green: 0.85, blue: 0.70), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: pom.secondsLeft)

                VStack(spacing: 2) {
                    let m = pom.secondsLeft / 60
                    let s = pom.secondsLeft % 60
                    Text(String(format: "%d:%02d", m, s))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text(phaseName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(width: 120, height: 120)
            .frame(maxWidth: .infinity)

            // Session dots
            HStack(spacing: 6) {
                ForEach(0..<pom.sessionsPerSet, id: \.self) { i in
                    Circle()
                        .fill(i < pom.completed % pom.sessionsPerSet
                              ? Color(red: 0.0, green: 0.85, blue: 0.70)
                              : Color.white.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
                Spacer()
                Text("\(pom.completed) done")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }

            // Focus duration stepper
            HStack {
                Text("Focus")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Stepper("\(pom.focusMins) min", value: Binding(
                    get: { pom.focusMins },
                    set: { pom.setFocusMins($0) }
                ), in: 5...60, step: 5)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
                .labelsHidden()
                Text("\(pom.focusMins) min")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var phaseName: String {
        switch pom.phase {
        case .focus:      return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak:  return "Long Break"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Battery Widget
// ─────────────────────────────────────────────────────────────────────────────

private struct BatteryWidget: View {
    @State private var percent  = 100
    @State private var charging = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: percent)
            VStack(spacing: 0) {
                Text("\(percent)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7))
                        .foregroundColor(.yellow)
                }
            }
        }
        .frame(width: 50, height: 50)
        .frame(width: 68)
        .onAppear { updateBattery() }
        .onReceive(timer) { _ in updateBattery() }
    }

    private var ringColor: Color {
        if charging    { return .green }
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Weather Widget + Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

private struct WeatherWidget: View {
    @StateObject private var svc = WeatherService()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: svc.weather.sfSymbol)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(svc.isLoaded ? "\(svc.weather.tempF)°" : "--")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(svc.isLoaded ? svc.weather.location : "Loading…")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 120)
        .onAppear { svc.fetch() }
    }
}

private struct WeatherDetailPanel: View {
    @StateObject private var svc = WeatherService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: svc.weather.sfSymbol)
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(svc.weather.tempF)°F")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text(svc.weather.condition)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("H: \(svc.weather.highF)°")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text("L: \(svc.weather.lowF)°")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            Text(svc.weather.location)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .onAppear { svc.fetch() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Now Playing Widget + Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

private struct NowPlayingWidget: View {
    @ObservedObject private var np = NowPlayingService.shared

    var body: some View {
        HStack(spacing: 8) {
            // Album art
            if let art = np.info.artwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.2))
                    )
            }

            if np.info.hasContent {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.info.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(np.info.artist)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(width: 90, alignment: .leading)

                HStack(spacing: 8) {
                    Button { np.previousTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Button { np.togglePlayPause() } label: {
                        Image(systemName: np.info.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button { np.nextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Nothing playing")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 200, maxWidth: 240)
    }
}

private struct NowPlayingDetailPanel: View {
    @ObservedObject private var np = NowPlayingService.shared

    var body: some View {
        HStack(spacing: 14) {
            if let art = np.info.artwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(np.info.title.isEmpty ? "Nothing Playing" : np.info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(np.info.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                HStack(spacing: 14) {
                    Button { np.previousTrack() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.6))
                    }.buttonStyle(.plain)
                    Button { np.togglePlayPause() } label: {
                        Image(systemName: np.info.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20)).foregroundColor(.white)
                    }.buttonStyle(.plain)
                    Button { np.nextTrack() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.6))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App Launcher Widget + Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

private let pinnedAppsKey = "mira_dock_pinned_apps"

private func defaultPinnedApps() -> [String] {
    ["com.apple.Safari", "com.apple.Music", "com.apple.Notes", "com.apple.finder"]
}

private struct AppLauncherWidget: View {
    @State private var apps: [(id: String, icon: NSImage?)] = []

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(26)), GridItem(.fixed(26))], spacing: 4) {
            ForEach(apps.prefix(4), id: \.id) { app in
                Button { launch(app.id) } label: {
                    Group {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app").font(.system(size: 16)).foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 90)
        .onAppear { loadApps() }
    }

    private func loadApps() {
        let ids = UserDefaults.standard.stringArray(forKey: pinnedAppsKey) ?? defaultPinnedApps()
        apps = ids.map { id in
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path ?? ""
            let icon = NSWorkspace.shared.icon(forFile: path)
            return (id: id, icon: icon.isValid ? icon : nil)
        }
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

private struct AppLauncherDetailPanel: View {
    @State private var apps: [(id: String, name: String, icon: NSImage?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned Apps")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 10) {
                ForEach(apps, id: \.id) { app in
                    Button { launch(app.id) } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().scaledToFit()
                                } else {
                                    Image(systemName: "app").font(.system(size: 24)).foregroundColor(.white.opacity(0.3))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(app.name)
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { loadApps() }
    }

    private func loadApps() {
        let ids = UserDefaults.standard.stringArray(forKey: pinnedAppsKey) ?? defaultPinnedApps()
        apps = ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let path = url.path
            let icon = NSWorkspace.shared.icon(forFile: path)
            let name = url.deletingPathExtension().lastPathComponent
            return (id: id, name: name, icon: icon.isValid ? icon : nil)
        }
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Quick Toggles Widget + Detail Panel
// ─────────────────────────────────────────────────────────────────────────────

private struct QuickTogglesWidget: View {
    @State private var darkMode   = isDarkMode()
    @State private var wifiOn     = true
    @State private var dndOn      = false

    var body: some View {
        HStack(spacing: 6) {
            toggleCircle(icon: "wifi", label: "Wi-Fi", color: .blue, on: wifiOn) {
                toggleWifi()
            }
            toggleCircle(icon: "moon.fill", label: "Dark", color: .purple, on: darkMode) {
                toggleDarkMode()
                darkMode = isDarkMode()
            }
            toggleCircle(icon: "bell.slash.fill", label: "DND", color: .gray, on: dndOn) {
                dndOn.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 118)
    }

    private func toggleCircle(icon: String, label: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(on ? .white : .white.opacity(0.35))
                .frame(width: 32, height: 32)
                .background(Circle().fill(on ? color : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func toggleWifi() {
        wifiOn.toggle()
        let state = wifiOn ? "on" : "off"
        shell("networksetup -setairportpower en0 \(state)")
    }

    private func toggleDarkMode() {
        shell("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'")
    }
}

private func isDarkMode() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
}

private struct TogglesDetailPanel: View {
    @State private var darkMode = isDarkMode()
    @State private var wifiOn   = true
    @State private var btOn     = true
    @State private var dndOn    = false

    private let toggleItems: [(String, String, Color, String)] = [
        ("Wi-Fi",      "wifi",              .blue,   "wifi"),
        ("Bluetooth",  "bluetooth",         .blue,   "bt"),
        ("Dark Mode",  "moon.fill",         .purple, "dark"),
        ("Focus",      "moon.circle.fill",  .orange, "focus"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Toggles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            VStack(spacing: 6) {
                panelRow("Wi-Fi", icon: "wifi", color: .blue, on: wifiOn) {
                    wifiOn.toggle()
                    let s = wifiOn ? "on" : "off"
                    shell("networksetup -setairportpower en0 \(s)")
                }
                panelRow("Dark Mode", icon: "moon.fill", color: .purple, on: darkMode) {
                    darkMode.toggle()
                    shell("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode'")
                }
                panelRow("Do Not Disturb", icon: "bell.slash.fill", color: .gray, on: dndOn) {
                    dndOn.toggle()
                }
            }
        }
    }

    private func panelRow(_ label: String, icon: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 24)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { _ in action() }))
                .toggleStyle(.switch)
                .tint(color)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sound Meter Widget
// ─────────────────────────────────────────────────────────────────────────────

private struct SoundMeterWidget: View {
    @ObservedObject private var np = NowPlayingService.shared
    @State private var levels: [CGFloat] = Array(repeating: 0.3, count: 8)
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor(i))
                    .frame(width: 4, height: max(4, levels[i] * 44))
                    .animation(.easeInOut(duration: 0.15), value: levels[i])
            }
        }
        .frame(width: 68)
        .onAppear { startAnimating() }
        .onDisappear { task?.cancel() }
        .onChange(of: np.info.isPlaying) { _, _ in }
    }

    private func barColor(_ i: Int) -> Color {
        let h = levels[i]
        if h > 0.75 { return Color(red: 0.2, green: 0.9, blue: 0.4) }
        if h > 0.5  { return Color(red: 0.2, green: 0.9, blue: 0.4).opacity(0.8) }
        return Color(red: 0.2, green: 0.9, blue: 0.4).opacity(0.5)
    }

    private func startAnimating() {
        task = Task {
            while !Task.isCancelled {
                let playing = await MainActor.run { np.info.isPlaying }
                await MainActor.run {
                    withAnimation {
                        if playing {
                            levels = (0..<8).map { _ in CGFloat.random(in: 0.15...1.0) }
                        } else {
                            levels = levels.map { max(0.05, $0 * 0.6) }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shell helper
// ─────────────────────────────────────────────────────────────────────────────

@discardableResult
private func shell(_ cmd: String) -> Int32 {
    let p = Process()
    p.launchPath = "/bin/zsh"
    p.arguments  = ["-c", cmd]
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
