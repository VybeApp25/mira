import AppKit
import SwiftUI

// MARK: - PointToService
// Renders a teal triangle that arcs from the notch to a target screen coordinate.
// Animation spec reverse-engineered from HeyClicky's ClickyComputerUseRuntime:
//   cubic bezier  — start_handle=0.3, end_handle=0.3
//   arc_size=0.25 — perpendicular deflection = 25% of straight-line distance
//   arc_flow=0.0  — symmetric arc
//   spring=0.72   — rotation settling damping
//   glide=750 ms

@MainActor
final class PointToService: ObservableObject {
    static let shared = PointToService()
    private init() {}

    // True while the cursor triangle is in flight or landing.
    @Published private(set) var isActive: Bool = false

    private var window:   NSWindow?
    private var hosting:  NSHostingView<_PointToRoot>?
    private var vm        = _PointToVM()
    private var autoHide: Task<Void, Never>?

    // pt: normalized (0-1), origin top-left
    func point(toNormalized pt: CGPoint) {
        guard pt != .zero else { return }
        setupWindowIfNeeded()
        window?.orderFrontRegardless()
        vm.fire(pt)
        isActive = true

        autoHide?.cancel()
        autoHide = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self.window?.orderOut(nil)
            self.isActive = false
        }
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
        win.ignoresMouseEvents = true
        win.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 20)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let root     = _PointToRoot(vm: vm, screenSize: screen.frame.size)
        let hostView = NSHostingView(rootView: root)
        hostView.frame                  = NSRect(origin: .zero, size: screen.frame.size)
        hostView.wantsLayer             = true
        hostView.layer?.backgroundColor = CGColor.clear
        win.contentView                 = hostView

        window  = win
        hosting = hostView
    }
}

// MARK: - ViewModel

@MainActor
final class _PointToVM: ObservableObject {
    @Published private(set) var target:    CGPoint = .zero
    @Published private(set) var animToken: UUID    = UUID()

    func fire(_ pt: CGPoint) {
        target    = pt
        animToken = UUID()
    }
}

// MARK: - Root

struct _PointToRoot: View {
    @ObservedObject var vm: _PointToVM
    let screenSize: CGSize

    var body: some View {
        _FlyingTriangleView(target: vm.target, screenSize: screenSize)
            .id(vm.animToken)
    }
}

// MARK: - Flying triangle view

private struct _FlyingTriangleView: View {
    let target:     CGPoint   // normalized 0-1, origin top-left
    let screenSize: CGSize

    // Notch center in SwiftUI coords
    private var notchPt: CGPoint { CGPoint(x: screenSize.width / 2, y: 16) }
    private var destPt:  CGPoint { CGPoint(x: target.x * screenSize.width,
                                            y: target.y * screenSize.height) }

    // Cubic bezier control points using HeyClicky's exact parameters:
    // start_handle=0.3, end_handle=0.3, arc_size=0.25, arc_flow=0.0
    private var bezierPoints: (c1: CGPoint, c2: CGPoint) {
        let p0 = notchPt, p1 = destPt
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let dist = sqrt(dx*dx + dy*dy)
        guard dist > 1 else { return (p0, p1) }

        // Perpendicular unit vector (rotated 90° CCW)
        let nx = -dy / dist, ny = dx / dist
        let deflect = dist * 0.25  // arc_size = 0.25

        let c1 = CGPoint(x: p0.x + 0.3*dx + deflect*nx,
                         y: p0.y + 0.3*dy + deflect*ny)
        let c2 = CGPoint(x: p1.x - 0.3*dx + deflect*nx,
                         y: p1.y - 0.3*dy + deflect*ny)
        return (c1, c2)
    }

    @State private var startTime: Date? = nil

    var body: some View {
        let bp = bezierPoints
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let elapsed = startTime.map { ctx.date.timeIntervalSince($0) } ?? 0
            _TriangleCanvas(
                elapsed:    elapsed,
                notch:      notchPt,
                c1:         bp.c1,
                c2:         bp.c2,
                dest:       destPt,
                frameSize:  screenSize
            )
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear { startTime = Date() }
    }
}

// MARK: - Canvas

private struct _TriangleCanvas: View {
    let elapsed:   Double
    let notch, c1, c2, dest: CGPoint
    let frameSize: CGSize

    // HeyClicky defaults
    private let glideDur:  Double = 0.750
    private let fadeAt:    Double = 0.900
    private let fadeDur:   Double = 0.380
    private let springK:   Double = 0.72   // rotation settle damping

    // Progress along the bezier path (ease-in-out)
    private var t: CGFloat {
        easeInOut(CGFloat(min(1.0, elapsed / glideDur)))
    }

    // Alpha
    private var alpha: CGFloat {
        guard elapsed > 0 else { return 0 }
        guard elapsed > fadeAt else { return 1 }
        return max(0, CGFloat(1 - (elapsed - fadeAt) / fadeDur))
    }

    var body: some View {
        Canvas { ctx, _ in
            guard alpha > 0.01 else { return }

            let pos      = cubicBezier(t: t)
            let tangent  = cubicBezierTangent(t: t)
            let rawAngle = atan2(tangent.y, tangent.x)

            // Spring-damp the rotation as the cursor approaches the target (HeyClicky spring=0.72).
            // Near arrival (t > 0.8), blend toward the final rest angle.
            let finalAngle = atan2(dest.y - c2.y, dest.x - c2.x)
            let blend      = max(0, (t - 0.80) / 0.20)
            let angle      = rawAngle * (1 - blend) + finalAngle * blend

            // Scale: rises from 1→1.7 at mid-flight, returns to 1 at destination
            let scale = 1.0 + sin(t * .pi) * 0.70

            // Glow behind triangle
            let glowR: CGFloat = 14 * scale
            ctx.opacity = alpha * 0.18
            ctx.fill(Path(ellipseIn: .init(center: pos, r: glowR)), with: .color(miraTeale))

            // Triangle — equilateral, pointing in direction of travel
            ctx.opacity = alpha
            ctx.fill(trianglePath(at: pos, angle: angle, size: 10 * scale),
                     with: .color(miraTeale))

            // Arrival ring: expands and fades as cursor lands
            if t > 0.78 {
                let phase: CGFloat = (t - 0.78) / 0.22
                let rr: CGFloat = 8 + phase * 18
                var ring = Path()
                ring.addEllipse(in: .init(center: dest, r: rr))
                ctx.opacity = alpha * (1 - phase) * 0.60
                ctx.stroke(ring, with: .color(miraTeale), lineWidth: 1.5)
            }

            // Second, subtler ring with slight delay for the "ripple" feel
            if t > 0.86 {
                let phase2: CGFloat = (t - 0.86) / 0.14
                let rr2: CGFloat = 14 + phase2 * 14
                var ring2 = Path()
                ring2.addEllipse(in: .init(center: dest, r: rr2))
                ctx.opacity = alpha * (1 - phase2) * 0.30
                ctx.stroke(ring2, with: .color(miraTeale), lineWidth: 1.0)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    // Equilateral triangle centered at `pos`, pointing in direction `angle`
    private func trianglePath(at pos: CGPoint, angle: CGFloat, size: CGFloat) -> Path {
        let h  = size             // height
        let hw = size * 0.65      // half-width at base

        // Tip forward, two base corners backward
        let tip  = CGPoint(x: pos.x + h  * cos(angle),       y: pos.y + h  * sin(angle))
        let bl   = CGPoint(x: pos.x - hw * sin(angle) - (h*0.4)*cos(angle),
                           y: pos.y + hw * cos(angle) - (h*0.4)*sin(angle))
        let br   = CGPoint(x: pos.x + hw * sin(angle) - (h*0.4)*cos(angle),
                           y: pos.y - hw * cos(angle) - (h*0.4)*sin(angle))

        var p = Path()
        p.move(to: tip)
        p.addLine(to: bl)
        p.addLine(to: br)
        p.closeSubpath()
        return p
    }

    // MARK: - Cubic bezier

    private func cubicBezier(t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt*mt*mt*notch.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*dest.x,
            y: mt*mt*mt*notch.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*dest.y
        )
    }

    // Tangent of the cubic bezier (first derivative)
    private func cubicBezierTangent(t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: 3*mt*mt*(c1.x-notch.x) + 6*mt*t*(c2.x-c1.x) + 3*t*t*(dest.x-c2.x),
            y: 3*mt*mt*(c1.y-notch.y) + 6*mt*t*(c2.y-c1.y) + 3*t*t*(dest.y-c2.y)
        )
    }

    private func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2*t*t : 1 - pow(-2*t + 2, 2) / 2
    }
}

// MARK: - CGRect helper

private extension CGRect {
    init(center: CGPoint, r: CGFloat) {
        self.init(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }
}
