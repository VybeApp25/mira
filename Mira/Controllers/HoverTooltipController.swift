import AppKit
import SwiftUI

// MARK: - Tooltip view

private struct TooltipView: View {
    let text: String
    let isLoading: Bool
    let isExplanation: Bool

    var body: some View {
        HStack(spacing: isLoading ? 6 : 0) {
            if isLoading {
                ProgressIndicator()
            }
            Text(text)
                .font(.system(size: isExplanation ? 12 : 12, weight: isExplanation ? .regular : .semibold))
                .foregroundColor(isLoading ? .white.opacity(0.6) : .white)
                .lineLimit(isExplanation ? 3 : 1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: !isExplanation, vertical: true)
                .frame(maxWidth: isExplanation ? 280 : .infinity)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
                .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
        )
        .fixedSize(horizontal: !isExplanation, vertical: true)
    }
}

private struct ProgressIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let v = NSProgressIndicator()
        v.style = .spinning
        v.controlSize = .small
        v.isIndeterminate = true
        v.startAnimation(nil)
        return v
    }
    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}
}

// MARK: - Controller

/// Manages a floating borderless NSPanel that shows hover summaries and explanations.
@MainActor
final class HoverTooltipController {

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    // MARK: - Public API

    func showLoading(near cursorPos: CGPoint) {
        present(text: "Explaining…", near: cursorPos, isLoading: true, isExplanation: false, autohide: false)
    }

    func show(text: String, near cursorPos: CGPoint, isExplanation: Bool = false) {
        present(text: text, near: cursorPos, isLoading: false, isExplanation: isExplanation, autohide: true)
    }

    func hide() {
        hideWork?.cancel()
        guard let p = panel, p.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        } completionHandler: {
            p.orderOut(nil)
        }
    }

    // MARK: - Private

    private func present(text: String, near cursorPos: CGPoint, isLoading: Bool, isExplanation: Bool, autohide: Bool) {
        hideWork?.cancel()
        ensurePanel()
        guard let p = panel else { return }

        let view = TooltipView(text: text, isLoading: isLoading, isExplanation: isExplanation)
        (p.contentView as? NSHostingView<TooltipView>)?.rootView = view

        let contentSize = (p.contentView as? NSHostingView<TooltipView>)?.fittingSize ?? CGSize(width: 200, height: 34)
        p.setFrame(CGRect(origin: origin(for: cursorPos, size: contentSize), size: contentSize), display: false)

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1.0
        }

        guard autohide else { return }
        let delay: TimeInterval = isExplanation ? 8 : 4
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 9)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: TooltipView(text: "", isLoading: false, isExplanation: false))
        panel = p
    }

    private func origin(for cursor: CGPoint, size: CGSize) -> CGPoint {
        var x = cursor.x + 14
        var y = cursor.y + 18
        if let screen = NSScreen.main {
            x = min(x, screen.frame.maxX - size.width - 8)
            y = min(y, screen.frame.maxY - size.height - 8)
            x = max(x, screen.frame.minX + 8)
            y = max(y, screen.frame.minY + 8)
        }
        return CGPoint(x: x, y: y)
    }
}
