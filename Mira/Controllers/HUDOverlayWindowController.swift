import AppKit
import SwiftUI

// MARK: - HUDOverlayWindowController
//
// Floating volume/brightness HUD, modeled on HoverTooltipController's
// borderless NSPanel template. Uses .screenSaver level (not .statusBar+9 like
// HoverTooltipController) + fullScreenAuxiliary collection behavior so it
// shows over fullscreen video/apps — matching stock macOS's own HUD, which
// users already expect to see even in fullscreen.

@MainActor
final class HUDOverlayWindowController {
    static let shared = HUDOverlayWindowController()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .miraVolumeHUDChanged, object: nil, queue: .main
        ) { [weak self] note in
            let level = note.userInfo?["level"] as? Float ?? 0
            self?.show(symbol: level <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", level: Double(level))
        }
        NotificationCenter.default.addObserver(
            forName: .miraBrightnessHUDChanged, object: nil, queue: .main
        ) { [weak self] note in
            let level = note.userInfo?["level"] as? Double ?? 0
            self?.show(symbol: "sun.max.fill", level: level)
        }
    }

    private func show(symbol: String, level: Double) {
        hideWork?.cancel()
        ensurePanel()
        guard let p = panel else { return }

        let view = SystemHUDView(symbol: symbol, level: level)
        (p.contentView as? NSHostingView<SystemHUDView>)?.rootView = view

        let size = (p.contentView as? NSHostingView<SystemHUDView>)?.fittingSize ?? CGSize(width: 180, height: 56)
        p.setFrame(CGRect(origin: origin(size: size), size: size), display: false)

        p.alphaValue = 1
        p.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func hide() {
        guard let p = panel, p.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        } completionHandler: {
            p.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 180, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SystemHUDView(symbol: "speaker.wave.3.fill", level: 0))
        panel = p
    }

    private func origin(size: CGSize) -> CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.minY + screen.frame.height * 0.16
        return CGPoint(x: x, y: y)
    }
}
