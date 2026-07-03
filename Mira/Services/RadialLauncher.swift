import Cocoa
import SwiftUI

// MARK: - Models

struct LauncherApp: Identifiable {
    let id = UUID()
    let name: String
    let icon: NSImage?
    let hidesAfter: Bool
    let isRunning: Bool        // shows a running-indicator dot under the icon
    let activate: () -> Void
}

/// A user-configured app in the wheel palette, with Launchy-style per-app options.
struct PaletteApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var hideOthers = false        // hide all other apps when this one launches
    var hidesAfterLaunch = true   // dismiss the wheel after launching this app
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

enum WheelSize: String, Codable, CaseIterable, Identifiable {
    case tiny, small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var outer: CGFloat {
        switch self {
        case .tiny:   return 96
        case .small:  return 124
        case .medium: return 152
        case .large:  return 192
        }
    }
}

// MARK: - RadialLauncherModel
//
// Utility #3: a Launchy-style radial "wheel" app switcher. A user-built app
// palette (unlimited on Ultra, capped on Pro) shown as a segmented donut, with
// configurable size/thickness, open-at-cursor, and per-app launch options.

@MainActor
final class RadialLauncherModel: ObservableObject {
    static let shared = RadialLauncherModel()
    private init() {
        if let data = UserDefaults.standard.data(forKey: paletteKey),
           let decoded = try? JSONDecoder().decode([PaletteApp].self, from: data) {
            palette = decoded
        }
        size = WheelSize(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .medium
        let t = UserDefaults.standard.double(forKey: thicknessKey)
        thickness = t == 0 ? 62 : t
        showAtCursor = UserDefaults.standard.bool(forKey: cursorKey)
    }

    private let paletteKey   = "mira_radial_palette"
    private let sizeKey      = "mira_radial_size"
    private let thicknessKey = "mira_radial_thickness"
    private let cursorKey    = "mira_radial_cursor"

    @Published var palette: [PaletteApp] = []
    @Published var size: WheelSize = .medium       { didSet { UserDefaults.standard.set(size.rawValue, forKey: sizeKey) } }
    @Published var thickness: Double = 62          { didSet { UserDefaults.standard.set(thickness, forKey: thicknessKey) } }
    @Published var showAtCursor: Bool = false      { didSet { UserDefaults.standard.set(showAtCursor, forKey: cursorKey) } }
    private(set) var recents: [String] = []

    var paletteLimit: Int { EntitlementService.shared.plan == .ultra ? .max : 8 }
    var atLimit: Bool { palette.count >= paletteLimit }

    func startTrackingRecents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      let bid = app.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier else { return }
                self.recents.removeAll { $0 == bid }
                self.recents.insert(bid, at: 0)
                if self.recents.count > 12 { self.recents.removeLast(self.recents.count - 12) }
            }
        }
    }

    // MARK: Palette editing

    func addApp(path: String) {
        guard !atLimit, !palette.contains(where: { $0.path == path }) else { return }
        palette.append(PaletteApp(path: path))
        save()
    }
    func removeApp(_ id: UUID) { palette.removeAll { $0.id == id }; save() }
    func update(_ app: PaletteApp) {
        guard let i = palette.firstIndex(where: { $0.id == app.id }) else { return }
        palette[i] = app
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(palette) { UserDefaults.standard.set(data, forKey: paletteKey) }
    }

    // MARK: Apps shown in the wheel

    func launcherApps() -> [LauncherApp] {
        if !palette.isEmpty {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
            return palette.map { pa in
                let bid = Bundle(url: URL(fileURLWithPath: pa.path))?.bundleIdentifier
                return LauncherApp(name: pa.name,
                            icon: NSWorkspace.shared.icon(forFile: pa.path),
                            hidesAfter: pa.hidesAfterLaunch,
                            isRunning: bid.map { running.contains($0) } ?? false,
                            activate: { [weak self] in self?.launch(pa) })
            }
        }
        // Fallback before the user builds a palette: recent apps (all running).
        var apps: [LauncherApp] = []
        for bid in recents.prefix(6) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else { continue }
            apps.append(LauncherApp(name: app.localizedName ?? bid, icon: app.icon,
                                    hidesAfter: true, isRunning: true, activate: { app.activate() }))
        }
        return apps
    }

    private func launch(_ pa: PaletteApp) {
        let url = URL(fileURLWithPath: pa.path)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] app, _ in
            guard pa.hideOthers else { return }
            DispatchQueue.main.async { self?.hideOthers(except: app?.bundleIdentifier) }
        }
    }

    private func hideOthers(except bid: String?) {
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            if a.bundleIdentifier == bid || a.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            a.hide()
        }
    }
}

// MARK: - Option-tap hotkey

@MainActor
final class RadialLauncherHotkey {
    static let shared = RadialLauncherHotkey()
    private init() {}

    private var globalMonitor: Any?
    private var localMonitor:  Any?
    private var optionDownAt: Date?
    private var contaminated = false
    private let tapMaxDuration: TimeInterval = 0.4

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] e in MainActor.assumeIsolated { self?.handle(e) } }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] e in MainActor.assumeIsolated { self?.handle(e) }; return e }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            let optionDown = e.modifierFlags.contains(.option)
            let otherMods  = !e.modifierFlags.intersection([.command, .control, .shift, .function]).isEmpty
            if optionDown {
                if optionDownAt == nil { optionDownAt = Date(); contaminated = false }
                if otherMods { contaminated = true }
            } else {
                if let t = optionDownAt, !contaminated, Date().timeIntervalSince(t) < tapMaxDuration {
                    if EntitlementService.shared.plan != .free { RadialLauncherController.shared.toggle() }
                }
                optionDownAt = nil
                contaminated = false
            }
        case .keyDown, .leftMouseDown, .rightMouseDown:
            if optionDownAt != nil { contaminated = true }
        default:
            break
        }
    }
}

// MARK: - Key-capable borderless window

private final class KeyableWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Controller

@MainActor
final class RadialLauncherController {
    static let shared = RadialLauncherController()
    private init() {}

    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? hide() : show() }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }

        let center: CGPoint
        if RadialLauncherModel.shared.showAtCursor {
            let m = NSEvent.mouseLocation
            center = CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y)
        } else {
            center = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        }

        let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.level              = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.hasShadow          = false
        win.acceptsMouseMovedEvents = true
        win.contentView = NSHostingView(rootView: RadialLauncherView(center: center, onClose: { [weak self] in self?.hide() }))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Wheel geometry

private struct WheelSegment: Shape {
    let index: Int
    let count: Int
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let gap = (1.5 * Double.pi / 180)
        let seg = 2 * Double.pi / Double(max(count, 1))
        let start = -Double.pi / 2 + Double(index) * seg + gap / 2
        let end   = start + seg - gap
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct DonutShape: Shape {
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p
    }
}

// MARK: - The wheel

struct RadialLauncherView: View {
    let center: CGPoint
    let onClose: () -> Void

    @ObservedObject private var model = RadialLauncherModel.shared
    @State private var apps: [LauncherApp] = []
    @State private var selected = 0
    @State private var overRing = false
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    private var outer: CGFloat { model.size.outer }
    private var inner: CGFloat { max(34, outer - CGFloat(model.thickness)) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.05).ignoresSafeArea().onTapGesture { onClose() }
            wheel
                .frame(width: outer * 2, height: outer * 2)
                .onTapGesture { overRing ? launch(selected) : onClose() }
                .position(center)
        }
        .focusable()
        .focused($focused)
        .onAppear { apps = model.launcherApps(); focused = true; installMouseMonitor() }
        .onDisappear { removeMouseMonitor() }
        .onKeyPress(.leftArrow)  { move(-1); return .handled }
        .onKeyPress(.upArrow)    { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1);  return .handled }
        .onKeyPress(.downArrow)  { move(1);  return .handled }
        .onKeyPress(.return)     { launch(selected); return .handled }
        .onKeyPress(.space)      { launch(selected); return .handled }
        .onExitCommand(perform: onClose)
    }

    private var wheel: some View {
        ZStack {
            DonutShape(inner: inner, outer: outer)
                .fill(.ultraThinMaterial, style: FillStyle(eoFill: true))
                .overlay(DonutShape(inner: inner, outer: outer).stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 4)

            // Static base wedges — independent of selection, so they're not
            // re-rasterized on every hover tick.
            ForEach(apps.indices, id: \.self) { idx in
                WheelSegment(index: idx, count: apps.count, inner: inner, outer: outer)
                    .fill(Color.white.opacity(0.06))
            }

            // The ONLY view that depends on `selected` — keeps hover snappy.
            if !apps.isEmpty {
                WheelSegment(index: selected, count: apps.count, inner: inner, outer: outer)
                    .fill(Color.accentColor.opacity(0.55))
            }

            ForEach(apps.indices, id: \.self) { idx in
                WheelSegment(index: idx, count: apps.count, inner: inner, outer: outer)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            }

            ForEach(apps.indices, id: \.self) { idx in
                if let icon = apps[idx].icon {
                    Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .position(iconPosition(idx))
                        .allowsHitTesting(false)
                }
            }

            // Running-indicator dot under any already-open app (like the Dock).
            ForEach(apps.indices, id: \.self) { idx in
                if apps[idx].isRunning {
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
                        .position(dotPosition(idx))
                        .allowsHitTesting(false)
                }
            }

            if apps.isEmpty {
                Text("Add apps in Settings")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                    .position(x: outer, y: outer)
            }
        }
    }

    private var iconSize: CGFloat { min(46, max(28, CGFloat(model.thickness) * 0.62)) }

    private func iconPosition(_ idx: Int) -> CGPoint {
        let seg = 2 * Double.pi / Double(max(apps.count, 1))
        let a = -Double.pi / 2 + (Double(idx) + 0.5) * seg
        let r = (inner + outer) / 2
        return CGPoint(x: outer + r * cos(a), y: outer + r * sin(a))
    }

    private func dotPosition(_ idx: Int) -> CGPoint {
        let p = iconPosition(idx)
        return CGPoint(x: p.x, y: p.y + iconSize / 2 + 5)
    }

    private func installMouseMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in
            self.updateSelection(e.locationInWindow, windowHeight: e.window?.frame.height)
            return e
        }
    }

    private func removeMouseMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Highlight the wedge under the cursor — driven by raw mouse-moved events for
    /// fluid tracking (SwiftUI's onContinuousHover stuttered here).
    private func updateSelection(_ windowPoint: NSPoint, windowHeight: CGFloat?) {
        guard let h = windowHeight else { return }
        let dx = windowPoint.x - center.x
        let dy = (h - windowPoint.y) - center.y         // window is bottom-left, view top-left
        let dist = hypot(dx, dy)
        guard !apps.isEmpty, dist >= inner, dist <= outer else { overRing = false; return }
        var phi = atan2(dy, dx) + Double.pi / 2
        phi = phi.truncatingRemainder(dividingBy: 2 * .pi)
        if phi < 0 { phi += 2 * .pi }
        overRing = true
        let idx = min(apps.count - 1, Int(phi / (2 * .pi / Double(apps.count))))
        if idx != selected { selected = idx }
    }

    private func move(_ delta: Int) {
        guard !apps.isEmpty else { return }
        selected = (selected + delta + apps.count) % apps.count
    }

    private func launch(_ idx: Int) {
        guard apps.indices.contains(idx) else { return }
        let app = apps[idx]
        app.activate()
        if app.hidesAfter { onClose() }
    }
}
