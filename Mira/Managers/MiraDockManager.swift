import AppKit
import SwiftUI
import IOKit.ps

@MainActor
final class MiraDockManager {
    static let shared = MiraDockManager()

    private var panel:          NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var appObserver:    NSObjectProtocol?
    private var mouseMonitor:   Any?
    private var hideTimer:      Timer?
    private var dockVisible     = true
    private let enabledKey      = "mira_dock_enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); newValue ? enable() : disable() }
    }

    private init() {}

    // MARK: - Enable / Disable

    func enable() {
        hideNativeDock()
        buildPanel()
        observeScreenChanges()
        observeActiveApp()
        startMouseTracking()
        NowPlayingService.shared.start()
    }

    func disable() {
        restoreNativeDock()
        panel?.close(); panel = nil
        stopMouseTracking()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        if let o = appObserver   { NotificationCenter.default.removeObserver(o); appObserver   = nil }
    }

    func restoreIfEnabled() {
        guard isEnabled else { return }
        enable()
    }

    // MARK: - Panel

    private func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame  = shownFrame(for: screen)

        if panel == nil {
            let p = NSPanel(
                contentRect: frame,
                styleMask:   [.borderless, .nonactivatingPanel],
                backing:     .buffered,
                defer:       false
            )
            p.isFloatingPanel    = true
            p.backgroundColor    = .clear
            p.isOpaque           = false
            p.hasShadow          = false
            // .fullScreenAuxiliary keeps the dock on all spaces including full-screen ones
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            // Use a level above .statusBar so it renders over full-screen apps
            p.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
            p.contentView        = NSHostingView(rootView: MiraDockView())
            panel = p
        } else {
            panel?.setFrame(frame, display: false)
        }
        dockVisible = true
        panel?.orderFrontRegardless()
    }

    // MARK: - Show / Hide animation

    func showDock() {
        guard let p = panel, !dockVisible else { return }
        dockVisible = true
        let frame = shownFrame(for: NSScreen.main ?? NSScreen.screens[0])
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration         = 0.32
            ctx.timingFunction   = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
        }
    }

    func hideDock() {
        guard let p = panel, dockVisible else { return }
        dockVisible = false
        let frame = hiddenFrame(for: NSScreen.main ?? NSScreen.screens[0])
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - Frame calculations

    private func shownFrame(for screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let h: CGFloat = 82
        let w: CGFloat = min(sf.width * 0.86, 1200)
        return NSRect(x: sf.minX + (sf.width - w) / 2,
                      y: sf.minY + 10,
                      width: w, height: h)
    }

    private func hiddenFrame(for screen: NSScreen) -> NSRect {
        var f = shownFrame(for: screen)
        f.origin.y = screen.frame.minY - f.height + 4  // 4px trigger strip stays visible
        return f
    }

    // MARK: - Mouse tracking (auto-hide + bottom-edge trigger)

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMouseMove() }
        }
    }

    private func stopMouseTracking() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        hideTimer?.invalidate(); hideTimer = nil
    }

    private func handleMouseMove() {
        guard isEnabled, let p = panel else { return }
        let mouse  = NSEvent.mouseLocation
        let screen = NSScreen.main ?? NSScreen.screens[0]

        let inDock       = p.frame.insetBy(dx: -10, dy: -10).contains(mouse)
        let nearBottom   = mouse.y < (screen.frame.minY + 12)

        if inDock || nearBottom {
            hideTimer?.invalidate(); hideTimer = nil
            if !dockVisible { showDock() }
        } else if dockVisible {
            if hideTimer == nil {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.hideDock() }
                }
            }
        }
    }

    // MARK: - Full-screen app detection

    private func observeActiveApp() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMouseMove() }
        }
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.buildPanel()
            }
        }
    }

    // MARK: - Native Dock

    private func hideNativeDock() {
        shell("defaults write com.apple.dock autohide -bool true")
        shell("defaults write com.apple.dock autohide-delay -float 1000")
        shell("defaults write com.apple.dock autohide-time-modifier -float 0")
        shell("killall Dock")
    }

    private func restoreNativeDock() {
        shell("defaults delete com.apple.dock autohide-delay")
        shell("defaults delete com.apple.dock autohide-time-modifier")
        shell("defaults write com.apple.dock autohide -bool false")
        shell("killall Dock")
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ cmd: String) -> Int32 {
        let p = Process(); p.launchPath = "/bin/zsh"; p.arguments = ["-c", cmd]
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
