import AppKit
import SwiftUI
import Combine

// MARK: - State

@MainActor
final class ResponseCardService: ObservableObject {
    static let shared = ResponseCardService()
    private init() {}

    @Published private(set) var artifacts: [ClaudeCodeArtifact] = []
    @Published private(set) var isVisible: Bool = false

    private var panel: NSPanel?

    // MARK: - API

    func show(artifacts: [ClaudeCodeArtifact]) {
        guard !artifacts.isEmpty else { return }
        self.artifacts = artifacts
        isVisible = true
        setupPanelIfNeeded()
        guard let p = panel else { return }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }
        // Slide up
        if let screen = NSScreen.main {
            let target = targetFrame(screen: screen)
            var start  = target
            start.origin.y -= 24
            p.setFrame(start, display: false)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
            }
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
            self?.isVisible = false
            self?.artifacts = []
        }
    }

    func append(artifact: ClaudeCodeArtifact) {
        artifacts.append(artifact)
        if !isVisible { show(artifacts: artifacts) }
    }

    // MARK: - Panel

    private func setupPanelIfNeeded() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let frame = targetFrame(screen: screen)
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
        host.frame = CGRect(origin: .zero, size: frame.size)
        p.contentView = host
        panel = p
    }

    private func targetFrame(screen: NSScreen) -> CGRect {
        // Sits just below the notch island (which is 252pt tall from top)
        // Horizontally centered, 520pt wide, 180pt tall
        let w: CGFloat = 520
        let h: CGFloat = 180
        let topGap: CGFloat = 268  // island bottom + 16pt gap
        return CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - topGap - h,
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
            artifacts: service.artifacts,
            onClose: { service.hide() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
