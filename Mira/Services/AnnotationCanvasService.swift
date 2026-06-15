import AppKit
import SwiftUI

// MARK: - Annotation Canvas (Teaching System M1)
//
// The live drawing surface. Generalizes PointToService's single-triangle
// overlay into a persistent, click-through canvas that renders a fixed
// vocabulary of guidance primitives. See docs/architecture/teaching_system.md §1.
//
// Honesty boundary: this canvas renders ONLY what it is handed. It never invents
// a position. Callers (the grounding gate / teaching engine) are responsible for
// passing grounded targets; an ungrounded annotation is a programming error, not
// a runtime fallback.
//
// All coordinates are normalized (0–1, top-left origin) — the same space
// ElementLocationDetector.normalizedPoint(...) produces — so annotations are
// multi-display-correct for free.

/// A single guidance mark, positioned in normalized (0–1, top-left) coordinates.
enum Annotation: Identifiable, Equatable {
    /// Arrowhead at `target`, short shaft trailing up-left, with optional label.
    case arrow(to: CGPoint, label: String?)
    /// Pulsing highlight ring centered on `target`.
    case ring(around: CGPoint, radiusPt: CGFloat)
    /// Numbered step badge at `point`.
    case badge(at: CGPoint, number: Int)
    /// Short instruction pill placed beside `target` (edge-aware), so the user
    /// reads what to do right where they're already looking.
    case callout(near: CGPoint, text: String)

    var id: String {
        switch self {
        case .arrow(let p, let l):   return "arrow-\(p.x)-\(p.y)-\(l ?? "")"
        case .ring(let p, let r):    return "ring-\(p.x)-\(p.y)-\(r)"
        case .badge(let p, let n):   return "badge-\(p.x)-\(p.y)-\(n)"
        case .callout(let p, let t): return "callout-\(p.x)-\(p.y)-\(t)"
        }
    }
}

@MainActor
final class AnnotationCanvasService: ObservableObject {
    static let shared = AnnotationCanvasService()
    private init() {}

    private var window:   NSWindow?
    private var vm        = _AnnotationVM()
    private var autoClear: Task<Void, Never>?

    /// Replaces the current annotations. If `autoClearAfter` is set, the canvas
    /// clears itself after that interval; otherwise annotations persist until
    /// `clear()` (the teaching engine clears them when a step advances).
    func show(_ annotations: [Annotation], autoClearAfter: TimeInterval? = nil) {
        guard !annotations.isEmpty else { clear(); return }
        setupWindowIfNeeded()
        window?.orderFrontRegardless()
        vm.annotations = annotations

        autoClear?.cancel()
        if let secs = autoClearAfter {
            autoClear = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        }
    }

    func clear() {
        autoClear?.cancel()
        vm.annotations = []
        window?.orderOut(nil)
    }

    private func setupWindowIfNeeded() {
        guard window == nil, let screen = NSScreen.main else { return }
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        win.backgroundColor    = .clear
        win.isOpaque           = false
        win.hasShadow          = false
        win.ignoresMouseEvents = true   // click-through: never blocks the app being taught
        win.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 19)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let root     = _AnnotationRoot(vm: vm, screenSize: screen.frame.size)
        let hostView = NSHostingView(rootView: root)
        hostView.frame                  = NSRect(origin: .zero, size: screen.frame.size)
        hostView.wantsLayer             = true
        hostView.layer?.backgroundColor = CGColor.clear
        win.contentView                 = hostView

        window = win
    }
}

// MARK: - ViewModel

@MainActor
final class _AnnotationVM: ObservableObject {
    @Published var annotations: [Annotation] = []
}

// MARK: - Root

private struct _AnnotationRoot: View {
    @ObservedObject var vm: _AnnotationVM
    let screenSize: CGSize

    var body: some View {
        // A single pulse clock shared by every primitive, so highlights breathe
        // together rather than flickering independently.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let pulse = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 2.4)
            _AnnotationCanvas(annotations: vm.annotations,
                              screenSize: screenSize,
                              pulse: CGFloat(pulse))
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Canvas

private struct _AnnotationCanvas: View {
    let annotations: [Annotation]
    let screenSize:  CGSize
    let pulse:       CGFloat   // 0–1 shared breathing clock

    private func screenPt(_ n: CGPoint) -> CGPoint {
        CGPoint(x: n.x * screenSize.width, y: n.y * screenSize.height)
    }

    var body: some View {
        Canvas { ctx, _ in
            for a in annotations {
                switch a {
                case .ring(let n, let r):    drawRing(ctx, at: screenPt(n), radius: r)
                case .arrow(let n, let lbl): drawArrow(ctx, to: screenPt(n), label: lbl)
                case .badge(let n, let num): drawBadge(ctx, at: screenPt(n), number: num)
                case .callout(let n, let t): drawCallout(ctx, near: screenPt(n), text: t)
                }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    // Pulsing highlight ring.
    private func drawRing(_ ctx: GraphicsContext, at p: CGPoint, radius: CGFloat) {
        let r = radius + pulse * 4
        var ring = Path()
        ring.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        var glow = ctx
        glow.opacity = 0.18 + 0.12 * pulse
        glow.stroke(ring, with: .color(miraTeale), lineWidth: 7)
        ctx.stroke(ring, with: .color(miraTeale), lineWidth: 2)
    }

    // Arrowhead at the target, short shaft trailing toward upper-left.
    private func drawArrow(_ ctx: GraphicsContext, to target: CGPoint, label: String?) {
        let len: CGFloat = 46
        let ang: CGFloat = .pi / 4            // shaft comes from upper-left (45°)
        let tail = CGPoint(x: target.x - len * cos(ang) * (1 + 0.05 * pulse),
                           y: target.y - len * sin(ang) * (1 + 0.05 * pulse))

        var shaft = Path()
        shaft.move(to: tail)
        shaft.addLine(to: target)
        ctx.stroke(shaft, with: .color(miraTeale), lineWidth: 3)

        // Arrowhead at target, pointing toward it (down-right).
        let head: CGFloat = 11
        let dir = atan2(target.y - tail.y, target.x - tail.x)
        let left  = CGPoint(x: target.x - head * cos(dir - .pi/7),
                            y: target.y - head * sin(dir - .pi/7))
        let right = CGPoint(x: target.x - head * cos(dir + .pi/7),
                            y: target.y - head * sin(dir + .pi/7))
        var tip = Path()
        tip.move(to: target); tip.addLine(to: left)
        tip.addLine(to: right); tip.closeSubpath()
        ctx.fill(tip, with: .color(miraTeale))

        if let label, !label.isEmpty {
            let text = Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            ctx.draw(text, at: CGPoint(x: tail.x - 4, y: tail.y - 12), anchor: .trailing)
        }
    }

    // Short instruction pill beside the target. Prefers the right side; flips to
    // the left near the screen edge, and clamps vertically so it stays on screen.
    private func drawCallout(_ ctx: GraphicsContext, near p: CGPoint, text: String) {
        let maxW:  CGFloat = 230
        let padH:  CGFloat = 11
        let padV:  CGFloat = 8
        let gap:   CGFloat = 36          // clear of the ~26pt ring + glow
        let margin: CGFloat = 12

        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        )
        let textSize = resolved.measure(in: CGSize(width: maxW, height: 600))
        let pillW = textSize.width + padH * 2
        let pillH = textSize.height + padV * 2

        var originX = p.x + gap                                   // prefer right of target
        if originX + pillW > screenSize.width - margin {
            originX = p.x - gap - pillW                           // flip to the left
        }
        originX = max(margin, min(originX, screenSize.width - pillW - margin))

        var originY = p.y - pillH / 2                            // vertically centered
        originY = min(max(margin, originY), screenSize.height - pillH - margin)

        let rect = CGRect(x: originX, y: originY, width: pillW, height: pillH)
        let pill = Path(roundedRect: rect, cornerRadius: 10, style: .continuous)

        // Soft halo, dark fill, teal hairline — matches the HUD's surface language.
        var halo = ctx
        halo.opacity = 0.5
        halo.addFilter(.shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2))
        halo.fill(pill, with: .color(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.97)))
        ctx.fill(pill, with: .color(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.97)))
        ctx.stroke(pill, with: .color(miraTeale.opacity(0.55)), lineWidth: 1)

        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    // Filled numbered badge.
    private func drawBadge(_ ctx: GraphicsContext, at p: CGPoint, number: Int) {
        let r: CGFloat = 13
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(miraTeale))
        ctx.stroke(circle, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        let num = Text("\(number)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.black.opacity(0.85))
        ctx.draw(num, at: p, anchor: .center)
    }
}
