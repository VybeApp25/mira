import Cocoa
import SwiftUI

// MARK: - Launcher app item

struct LauncherApp: Identifiable {
    let id = UUID()
    let name: String
    let icon: NSImage?
    let activate: () -> Void
}

// MARK: - RadialLauncherModel (favorites + recents)
//
// Utility #3: a Launchy-style radial "wheel" app switcher. Shows up to 3
// user-favorited apps + up to 3 recently-activated apps. Favorites are chosen in
// Settings (stored as app paths); recents are tracked live from activations.

@MainActor
final class RadialLauncherModel: ObservableObject {
    static let shared = RadialLauncherModel()
    private init() {
        favorites = UserDefaults.standard.stringArray(forKey: favKey) ?? ["", "", ""]
    }

    private let favKey = "mira_radial_favorites"
    @Published var favorites: [String]
    private(set) var recents: [String] = []

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

    func setFavorite(_ index: Int, path: String) {
        while favorites.count <= index { favorites.append("") }
        favorites[index] = path
        UserDefaults.standard.set(favorites, forKey: favKey)
    }

    func favoriteName(_ index: Int) -> String? {
        guard index < favorites.count, !favorites[index].isEmpty else { return nil }
        return URL(fileURLWithPath: favorites[index]).deletingPathExtension().lastPathComponent
    }

    func launcherApps() -> [LauncherApp] {
        var apps: [LauncherApp] = []
        var seen = Set<String>()

        for path in favorites.prefix(3) where !path.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            let bid = Bundle(url: url)?.bundleIdentifier ?? path
            guard seen.insert(bid).inserted else { continue }
            apps.append(LauncherApp(
                name: url.deletingPathExtension().lastPathComponent,
                icon: NSWorkspace.shared.icon(forFile: path),
                activate: { NSWorkspace.shared.open(url) }))
        }

        var added = 0
        for bid in recents where added < 3 {
            guard seen.insert(bid).inserted,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
            else { continue }
            apps.append(LauncherApp(name: app.localizedName ?? bid, icon: app.icon,
                                    activate: { app.activate() }))
            added += 1
        }
        return apps
    }
}

// MARK: - Option-tap hotkey (single clean tap of Option toggles the wheel)

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

// MARK: - Key-capable borderless window (so arrow keys / Enter reach the wheel)

private final class KeyableWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - RadialLauncherController (overlay window)

@MainActor
final class RadialLauncherController {
    static let shared = RadialLauncherController()
    private init() {}

    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? hide() : show() }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.level              = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.hasShadow          = false
        win.contentView = NSHostingView(rootView: RadialLauncherView(onClose: { [weak self] in self?.hide() }))
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

// MARK: - RadialLauncherView (the Launchy-style wheel)

struct RadialLauncherView: View {
    let onClose: () -> Void

    @State private var apps: [LauncherApp] = []
    @State private var selected = 0
    @FocusState private var focused: Bool

    private let outer: CGFloat = 150
    private let inner: CGFloat = 90

    var body: some View {
        ZStack {
            // Near-invisible catcher — click anywhere outside to dismiss.
            Color.black.opacity(0.05).ignoresSafeArea().onTapGesture { onClose() }

            wheel
                .frame(width: outer * 2, height: outer * 2)
        }
        .focusable()
        .focused($focused)
        .onAppear {
            apps = RadialLauncherModel.shared.launcherApps()
            focused = true
        }
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
                .overlay(
                    DonutShape(inner: inner, outer: outer)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 18, y: 4)

            ForEach(apps.indices, id: \.self) { idx in
                WheelSegment(index: idx, count: apps.count, inner: inner, outer: outer)
                    .fill(idx == selected ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.06))
                WheelSegment(index: idx, count: apps.count, inner: inner, outer: outer)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            }

            ForEach(apps.indices, id: \.self) { idx in
                if let icon = apps[idx].icon {
                    Button { launch(idx) } label: {
                        Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .position(iconPosition(idx))
                }
            }

            if apps.isEmpty {
                Text("Pick favorites in Settings")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func iconPosition(_ idx: Int) -> CGPoint {
        let seg = 2 * Double.pi / Double(max(apps.count, 1))
        let a = -Double.pi / 2 + (Double(idx) + 0.5) * seg
        let r = (inner + outer) / 2
        return CGPoint(x: outer + r * cos(a), y: outer + r * sin(a))
    }

    private func move(_ delta: Int) {
        guard !apps.isEmpty else { return }
        selected = (selected + delta + apps.count) % apps.count
    }

    private func launch(_ idx: Int) {
        guard apps.indices.contains(idx) else { return }
        apps[idx].activate()
        onClose()
    }
}
