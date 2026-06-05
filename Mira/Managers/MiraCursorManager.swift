import AppKit
import SwiftUI

// MARK: - Cursor view (blue arrow matching the Mira brand)
// SVG path from 40×40 viewBox, scaled to 28×28. Tip sits at ~(1, 1) in view-local coords.

private struct MiraArrowCursor: View {
    private let s: CGFloat = 28.0 / 40.0      // viewBox scale
    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        Canvas { ctx, _ in
            var p = Path()
            p.move(to:    pt(1.8,  4.4))
            p.addLine(to: pt(7.0, 36.2))
            p.addCurve(to: pt(10.6, 37.0),
                       control1: pt(7.3, 38.0), control2: pt(9.6, 38.5))
            p.addLine(to: pt(14.5, 31.3))
            p.addCurve(to: pt(22.0, 27.0),
                       control1: pt(16.2, 28.8), control2: pt(19.0, 27.2))
            p.addLine(to: pt(28.9, 26.5))
            p.addCurve(to: pt(30.0, 23.0),
                       control1: pt(30.7, 26.4), control2: pt(31.4, 24.1))
            p.addLine(to: pt(5.0,  2.5))
            p.addCurve(to: pt(1.7,  4.4),
                       control1: pt(3.6,  1.4), control2: pt(1.5,  2.5))
            p.closeSubpath()

            ctx.fill(p, with: .color(accent))
            ctx.stroke(p, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 0.8))
        }
        .frame(width: 28, height: 28)
        .shadow(color: accent.opacity(0.55), radius: 6, x: 0, y: 0)
    }

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
}

// MARK: - Manager

/// Replaces the system cursor with a Mira-branded glowing ring while the app is running.
/// Call activate() once at launch; deactivate() restores the system cursor on quit.
@MainActor
final class MiraCursorManager {

    static let shared = MiraCursorManager()

    private var panel: NSPanel?
    private var timer: Timer?
    private var active = false

    private init() {}

    func activate() {
        guard !active else { return }
        active = true
        buildPanel()
        CGDisplayHideCursor(kCGNullDirectDisplay)
        startTracking()
    }

    func deactivate() {
        guard active else { return }
        active = false
        timer?.invalidate()
        timer = nil
        CGDisplayShowCursor(kCGNullDirectDisplay)
        panel?.orderOut(nil)
    }

    // MARK: - Private

    // Cursor panel size: matches MiraArrowCursor frame + glow headroom
    private let panelSize = CGSize(width: 36, height: 36)

    private func buildPanel() {
        let p = NSPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 200)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: MiraArrowCursor())
        p.orderFrontRegardless()
        panel = p
    }

    private func startTracking() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func updatePosition() {
        guard let p = panel else { return }
        let pos = NSEvent.mouseLocation
        // Arrow tip is near top-left of the 28×28 canvas — position frame so tip aligns with pointer.
        // Panel is 36×36 (4pt glow padding on each side), tip at ~(5, 5) within panel.
        p.setFrameOrigin(CGPoint(x: pos.x - 5, y: pos.y - panelSize.height + 5))
    }
}
