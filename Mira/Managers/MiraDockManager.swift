import AppKit
import SwiftUI
import IOKit.ps

@MainActor
final class MiraDockManager {
    static let shared = MiraDockManager()

    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private let enabledKey = "mira_dock_enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            newValue ? enable() : disable()
        }
    }

    private init() {}

    // MARK: - Enable / Disable

    func enable() {
        hideNativeDock()
        showPanel()
        observeScreenChanges()
        NowPlayingService.shared.start()
    }

    func disable() {
        restoreNativeDock()
        panel?.close()
        panel = nil
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    // Restores saved state on launch (called from AppDelegate).
    func restoreIfEnabled() {
        guard isEnabled else { return }
        enable()
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

    // MARK: - Panel

    private func showPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame  = panelFrame(for: screen)

        if panel == nil {
            let p = NSPanel(
                contentRect: frame,
                styleMask:   [.borderless, .nonactivatingPanel],
                backing:     .buffered,
                defer:       false
            )
            p.isFloatingPanel        = true
            p.backgroundColor        = .clear
            p.isOpaque               = false
            p.hasShadow              = false
            p.level                  = .statusBar
            p.collectionBehavior     = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.contentView            = NSHostingView(rootView: MiraDockView())
            panel = p
        } else {
            panel?.setFrame(frame, display: false)
        }
        panel?.orderFrontRegardless()
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let sf   = screen.frame
        let h: CGFloat = 106
        let w: CGFloat = min(sf.width * 0.82, 1100)
        let x = sf.minX + (sf.width - w) / 2
        let y = sf.minY + 24
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showPanel() }
        }
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ cmd: String) -> Int32 {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments  = ["-c", cmd]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
