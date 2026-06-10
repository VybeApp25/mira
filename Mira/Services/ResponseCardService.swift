import AppKit
import SwiftUI
import Combine

// MARK: - State

@MainActor
final class ResponseCardService: ObservableObject {
    static let shared = ResponseCardService()
    private init() {}

    @Published private(set) var artifacts:    [ClaudeCodeArtifact] = []
    @Published private(set) var isVisible:    Bool = false
    @Published private(set) var isMinimized:  Bool = false

    private var panel: NSPanel?

    // MARK: - API

    func show(artifacts: [ClaudeCodeArtifact]) {
        guard !artifacts.isEmpty else { return }
        self.artifacts  = artifacts
        isVisible       = true
        isMinimized     = false
        setupPanelIfNeeded()
        guard let p = panel, let screen = NSScreen.main else { return }
        p.alphaValue = 0
        p.setFrame(cardFrame(screen: screen), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }
        // Slide up from below
        var start = cardFrame(screen: screen)
        start.origin.y -= 24
        p.setFrame(start, display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(cardFrame(screen: screen), display: true)
        }
    }

    func hide() {
        guard let p = panel, isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.isVisible   = false
            self?.isMinimized = false
            self?.artifacts   = []
        }
    }

    func minimize() {
        guard let p = panel, let screen = NSScreen.main, !isMinimized else { return }
        isMinimized = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(self.chipFrame(screen: screen), display: true)
        }
    }

    func restore() {
        guard let p = panel, let screen = NSScreen.main, isMinimized else { return }
        isMinimized = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(self.cardFrame(screen: screen), display: true)
        }
    }

    func append(artifact: ClaudeCodeArtifact) {
        artifacts.append(artifact)
        if !isVisible { show(artifacts: artifacts) }
    }

    // MARK: - Panel

    private func setupPanelIfNeeded() {
        if panel == nil {
            guard let screen = NSScreen.main else { return }
            // Start at card size; minimized path will resize later.
            let frame = cardFrame(screen: screen)
            let p = NSPanel(
                contentRect: frame,
                styleMask:   [.borderless, .nonactivatingPanel],
                backing:     .buffered,
                defer:       false
            )
            p.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 6)
            p.backgroundColor    = .clear
            p.isOpaque           = false
            p.hasShadow          = true
            p.alphaValue         = 0
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

            let host = NSHostingView(rootView: ResponseCardRootView(service: self))
            host.autoresizingMask = [.width, .height]
            host.frame = CGRect(origin: .zero, size: frame.size)
            p.contentView = host
            panel = p
        } else {
            // Re-entering show() while panel exists: snap back to card frame.
            guard let p = panel, let screen = NSScreen.main else { return }
            p.setFrame(cardFrame(screen: screen), display: false)
        }
    }

    // MARK: - Frames

    /// Full card panel: centered below the notch island.
    private func cardFrame(screen: NSScreen) -> CGRect {
        let w: CGFloat  = 520
        let h: CGFloat  = 180
        let topGap: CGFloat = 268   // island bottom + 16pt gap
        return CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - topGap - h,
            width: w,
            height: h
        )
    }

    /// Chip strip: compact rows docked to the right edge, vertically centered.
    private func chipFrame(screen: NSScreen) -> CGRect {
        let w: CGFloat    = 270
        let rowH: CGFloat = 52
        let vPad: CGFloat = 8
        let h = vPad + CGFloat(max(1, artifacts.count)) * rowH + vPad
        return CGRect(
            x: screen.frame.maxX - w - 12,
            y: screen.frame.midY - h / 2,
            width: w,
            height: h
        )
    }
}

// MARK: - Root SwiftUI host

struct ResponseCardRootView: View {
    @ObservedObject var service: ResponseCardService

    var body: some View {
        ResponseCardView(
            artifacts:    service.artifacts,
            isMinimized:  service.isMinimized,
            onClose:      { service.hide() },
            onMinimize:   { service.minimize() },
            onRestore:    { service.restore() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
