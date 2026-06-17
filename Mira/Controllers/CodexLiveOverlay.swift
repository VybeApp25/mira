import Cocoa
import SwiftUI

// MARK: - CodexLiveOverlay (Autonomy slice 2 — live on-screen drawing)
//
// A continuous, click-through annotation layer drawn over the real screen WHILE
// Codex computer-use drives the Mac — the spatial complement to CodexHUD's text
// log. As each Codex action streams in with coordinates (left_click, scroll,
// drag, …), the service calls `mark(rawX:rawY:)` and we draw an animated ring +
// arrow at that spot, à la HeyClicky. A short trail of recent marks fades behind
// the newest so the user can see where Codex just was.
//
// Unlike OverlayWindowController (one-shot Point-and-Ask guidance that
// auto-dismisses), this window persists for the whole run via begin()/end() and
// reuses ONE reactive SwiftUI view that observes `model`, so each new mark
// animates in without rebuilding the hosting view.
//
// COORDINATE MAPPING (the thing most likely to need calibration on the first real
// run): Codex's bundled computer-use plugin reports action coordinates in the
// pixel space of the screenshot it captured. For a raw CGDisplay capture on a
// Retina Mac that's native pixels, so we divide by the screen's backingScaleFactor
// to get SwiftUI points (top-left origin, matching the overlay canvas). If the
// first live run shows rings landing at ~2× offset or half-position, flip
// `assumePixelsAreNative` — that's the single knob.

@MainActor
final class CodexLiveOverlay {
    static let shared = CodexLiveOverlay()
    private init() {}

    /// If true, incoming coords are treated as native pixels and divided by the
    /// backing scale to reach points. If Codex already reports point-resolution
    /// coords, set this false. CALIBRATE ON FIRST REAL RUN.
    var assumePixelsAreNative = true

    private var window: NSWindow?
    private let model = CodexOverlayModel()
    private var fadeTimer: DispatchWorkItem?

    // MARK: - Lifecycle

    /// Show the overlay for a new control run and clear any prior marks.
    func begin() {
        fadeTimer?.cancel()
        makeWindowIfNeeded()
        model.annotations = []
        model.active = true
        window?.orderFrontRegardless()
    }

    /// Drop an animated ring + arrow at a Codex action point (raw plugin coords).
    func mark(rawX: Double, rawY: Double) {
        guard model.active, let point = screenPoint(rawX, rawY) else { return }

        // Small ring centered on the action point, with an arrow leading into it.
        let side: CGFloat = 46
        let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let from = CGPoint(x: point.x - 54, y: point.y - 54)   // arrow comes in from up-left

        let ring  = SharpieAnnotation(target: rect, style: .circle, color: .blue, strokeWidth: 3.5)
        let arrow = SharpieAnnotation(target: rect, style: .arrow(from: from), color: .blue, strokeWidth: 3.0)

        // Keep a short trail: newest pair plus a couple of fading older marks.
        var next = model.annotations
        next.append(contentsOf: [ring, arrow])
        if next.count > 6 { next.removeFirst(next.count - 6) }
        model.annotations = next
    }

    /// End the run: let the last mark linger briefly, then fade the layer out.
    func end() {
        fadeTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.model.active = false
            self?.model.annotations = []
            self?.window?.orderOut(nil)
        }
        fadeTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    // MARK: - Coordinate mapping

    private func screenPoint(_ x: Double, _ y: Double) -> CGPoint? {
        guard let screen = NSScreen.main else { return nil }
        let scale = assumePixelsAreNative ? screen.backingScaleFactor : 1
        let pts = CGPoint(x: x / scale, y: y / scale)
        // Clamp into the visible canvas so a bad coord can't draw off-screen.
        let size = screen.frame.size
        return CGPoint(
            x: min(max(pts.x, 0), size.width),
            y: min(max(pts.y, 0), size.height)
        )
    }

    // MARK: - Window

    private func makeWindowIfNeeded() {
        guard window == nil, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true   // never intercepts Codex's own clicks
        win.hasShadow = false
        win.contentView = NSHostingView(rootView: CodexLiveOverlayView(model: model, screenSize: frame.size))
        window = win
    }
}

// MARK: - Reactive model + view

@MainActor
final class CodexOverlayModel: ObservableObject {
    @Published var annotations: [SharpieAnnotation] = []
    @Published var active = false
}

private struct CodexLiveOverlayView: View {
    @ObservedObject var model: CodexOverlayModel
    let screenSize: CGSize

    var body: some View {
        SharpieOverlayView(annotations: model.annotations, screenSize: screenSize)
            .opacity(model.active ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: model.active)
    }
}
