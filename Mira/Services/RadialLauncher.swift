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
// Utility #3: the radial ring app switcher. Shows up to 3 user-favorited apps +
// up to 3 recently-activated apps. Favorites are chosen in Settings (stored as
// app paths); recents are tracked live from app activations.

@MainActor
final class RadialLauncherModel: ObservableObject {
    static let shared = RadialLauncherModel()
    private init() {
        favorites = UserDefaults.standard.stringArray(forKey: favKey) ?? ["", "", ""]
    }

    private let favKey = "mira_radial_favorites"
    @Published var favorites: [String]        // up to 3 app file paths
    private(set) var recents: [String] = []   // bundle IDs, most-recent first

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

    /// The 6-ish apps to show: up to 3 favorites then up to 3 recents (deduped).
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
                activate: { NSWorkspace.shared.open(url) }
            ))
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

// MARK: - Option-tap hotkey
//
// A single clean tap of the Option key toggles the launcher. "Clean" = Option
// pressed and released within 0.4s with no other key/modifier/click in between,
// so Option used inside a real shortcut never triggers it. Needs Accessibility /
// Input Monitoring (Mira already requests Accessibility).

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
                if let t = optionDownAt, !contaminated,
                   Date().timeIntervalSince(t) < tapMaxDuration {
                    if EntitlementService.shared.plan != .free {
                        RadialLauncherController.shared.toggle()
                    }
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
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
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

// MARK: - RadialLauncherView

struct RadialLauncherView: View {
    let onClose: () -> Void
    @State private var apps: [LauncherApp] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { onClose() }

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius: CGFloat = 150
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 2)
                        .frame(width: radius * 2 - 36, height: radius * 2 - 36)
                        .position(center)

                    ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                        let angle = (2 * Double.pi * Double(idx) / Double(max(apps.count, 1))) - .pi / 2
                        Button { app.activate(); onClose() } label: { tile(app) }
                            .buttonStyle(.plain)
                            .position(x: center.x + radius * cos(angle),
                                      y: center.y + radius * sin(angle))
                    }

                    if apps.isEmpty {
                        Text("Pick favorites in Settings, or open a few apps")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                            .position(center)
                    }
                }
            }
        }
        .onAppear { apps = RadialLauncherModel.shared.launcherApps() }
        .onExitCommand(perform: onClose)
    }

    private func tile(_ app: LauncherApp) -> some View {
        VStack(spacing: 5) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
            }
            Text(app.name)
                .font(.system(size: 10, weight: .medium)).foregroundColor(.white)
                .lineLimit(1).shadow(color: .black.opacity(0.6), radius: 2)
        }
        .frame(width: 86)
    }
}
