import AppKit
import SwiftUI
import Combine

// MARK: - FloatingButtonService
// Ported from HeyClicky's FloatingSessionButtonManager.
// Floats a gradient "buddy button" in the top-right corner during active sessions
// when the island is collapsed, giving the companion a persistent presence on screen.
// Clicking it fires .miraActivateText to re-open the island.

@MainActor
final class FloatingButtonService {
    static let shared = FloatingButtonService()
    private init() {}

    private var panel:       NSPanel?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func start(animController: AnimationController, miraState: MiraState) {
        Publishers.CombineLatest3(
            animController.$state,
            miraState.$realtimeState,
            animController.$hudMode
        )
        .combineLatest(miraState.$isLoading)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] combined, isLoading in
            let (islandState, realtimeState, hudMode) = combined
            let sessionActive = realtimeState != .idle || hudMode != .idle || isLoading
            let isExpanded    = islandState == .expanded
            if sessionActive && !isExpanded {
                self?.show()
            } else {
                self?.hide()
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Show / hide

    func show() {
        setupPanelIfNeeded()
        guard let p = panel else { return }
        if p.alphaValue > 0.5 {
            p.orderFrontRegardless()
            return
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }
    }

    func hide() {
        guard let p = panel, p.alphaValue > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0.0
        } completionHandler: {
            p.orderOut(nil)
        }
    }

    // MARK: - Panel setup

    private func setupPanelIfNeeded() {
        guard panel == nil, let screen = NSScreen.main else { return }

        let size   = CGSize(width: 52, height: 52)
        let margin: CGFloat = 16
        let topGap: CGFloat = 80   // below menu bar + status icons
        let origin = CGPoint(
            x: screen.frame.maxX - size.width - margin,
            y: screen.frame.maxY - topGap - size.height
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.alphaValue         = 0
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: _FloatingButtonRoot())
        host.frame = CGRect(origin: .zero, size: size)
        p.contentView = host
        panel = p
    }
}

// MARK: - Root

struct _FloatingButtonRoot: View {
    var body: some View {
        _FloatingButtonView()
            .frame(width: 52, height: 52)
    }
}

// MARK: - Button view (mirrors HeyClicky FloatingButtonView)

private struct _FloatingButtonView: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .miraActivateText, object: nil)
        } label: {
            ZStack {
                // Ambient glow halo — blooms on hover
                Circle()
                    .fill(miraTeale.opacity(isHovered ? 0.28 : 0.12))
                    .frame(width: 50, height: 50)
                    .blur(radius: isHovered ? 4 : 7)

                // Gradient circle: teal → violet matching Mira's identity palette
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [miraTeale, miraViolet],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "sparkle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                    )
                    .scaleEffect(isHovered ? 1.10 : 1.0)
                    .shadow(
                        color: miraTeale.opacity(isHovered ? 0.60 : 0.22),
                        radius: isHovered ? 9 : 5,
                        x: 0, y: 2
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                isHovered = h
            }
        }
    }
}
