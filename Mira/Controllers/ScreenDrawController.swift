import Cocoa

// MARK: - ScreenDrawController
//
// Lets the USER draw freehand marks / arrows directly on their screen to give Mira
// spatial context — "summarize the part I circled", "click the thing I drew an arrow
// at". The user-input mirror of CodexLiveOverlay (which draws where Mira *acts*).
//
// Built on the same interactive NSPanel pattern as HandoffService.HandoffSelectionView
// (the only other input-capable overlay): borderless .nonactivatingPanel, screenSaver
// level, ignoresMouseEvents=false. On commit it captures a CLEAN screenshot (SCK
// excludes Mira's own windows, so the panel's ink isn't doubled), composites the marks
// in crisply, and hands a DrawnContext to PendingDrawnContextService.
//
// Two modes:
//   • .standalone   — armed by the ⌃⌥D hotkey or the Control-tab button. Return commits,
//                     Escape cancels. The marks wait in PendingDrawnContextService for
//                     the next chat send / voice turn / autonomy task.
//   • .voiceCoupled — armed while holding the voice PTT key. The user draws while
//                     talking; RealtimeVoiceService calls commit() at end-of-turn.

enum DrawMode { case standalone, voiceCoupled }

@MainActor
final class ScreenDrawController {
    static let shared = ScreenDrawController()
    private init() {}

    private var panel: NSPanel?
    private var view: FreehandDrawingView?
    private var screenFrame: CGRect = .zero
    private(set) var mode: DrawMode = .standalone

    var isActive: Bool { panel != nil }

    // MARK: - Lifecycle

    /// Toggle standalone draw mode (the ⌃⌥D hotkey / Control-tab button entry point).
    func toggleStandalone() {
        if isActive { cancel() } else { begin(mode: .standalone) }
    }

    func begin(mode: DrawMode) {
        guard !isActive, let screen = NSScreen.main else { return }
        self.mode = mode
        self.screenFrame = screen.frame

        let panel = DrawPanel(
            contentRect: screen.frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.backgroundColor    = .clear
        panel.isOpaque           = false
        panel.hasShadow          = false
        panel.ignoresMouseEvents = false
        // Borderless panels can't become key by default → keyDown (Return/Esc) never
        // fires. DrawPanel overrides canBecomeKey; this lets the view receive keys.
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let v = FreehandDrawingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.commitOnReturn = (mode == .standalone)
        v.onCommit = { [weak self] in self?.handleStandaloneCommit() }
        v.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = v

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(v)
        NSCursor.crosshair.set()

        self.panel = panel
        self.view  = v
    }

    /// Capture + composite the current marks into a DrawnContext, then tear down.
    /// Returns nil if nothing was drawn. Async because it captures the screen.
    func commit() async -> DrawnContext? {
        guard isActive, let v = view, v.hasMarks else { cancel(); return nil }
        let strokes = v.strokes
        let arrows  = v.arrows
        let size    = v.bounds.size

        // Clean capture: SCK excludes Mira's own windows, so our still-visible panel
        // ink is NOT in this image — we composite the marks ourselves for crisp lines.
        guard let png = await ComputerUseService.shared.screenshot(),
              let clean = NSImage(data: png) else { cancel(); return nil }

        let annotated = composite(clean: clean, strokes: strokes, arrows: arrows, size: size)
        let normalized = normalize(strokes: strokes, arrows: arrows, size: size)

        tearDown()
        return DrawnContext(annotatedImage: annotated,
                            cleanImage: clean,
                            normalizedMarks: normalized,
                            displayFrame: screenFrame)
    }

    func cancel() { tearDown() }

    // MARK: - Private

    private func handleStandaloneCommit() {
        Task { [weak self] in
            guard let self else { return }
            if let ctx = await self.commit() {
                PendingDrawnContextService.shared.set(ctx)
                // Give the marks a destination: open Mira's text box so the user can
                // immediately ask about / act on what they circled (the chat consumes
                // the pending context). Without this, Send appeared to "do nothing".
                NotificationCenter.default.post(name: .miraActivateText, object: nil)
            }
        }
    }

    private func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        view  = nil
        NSCursor.arrow.set()
    }

    /// Draw the clean capture, then the user's red ink on top, in a points-sized image.
    /// View coords are AppKit bottom-left points; the clean image is sized in points
    /// with the screen origin aligned, so stroke points map 1:1 onto the image.
    private func composite(clean: NSImage, strokes: [[NSPoint]], arrows: [(NSPoint, NSPoint)], size: NSSize) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        clean.draw(in: NSRect(origin: .zero, size: size))

        let ink = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.95)
        ink.setStroke()

        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for pt in stroke.dropFirst() { path.line(to: pt) }
            path.stroke()
        }
        for (from, to) in arrows { drawArrow(from: from, to: to) }

        out.unlockFocus()
        return out
    }

    private func drawArrow(from: NSPoint, to: NSPoint) {
        let shaft = NSBezierPath()
        shaft.lineWidth = 4
        shaft.lineCapStyle = .round
        shaft.move(to: from)
        shaft.line(to: to)
        shaft.stroke()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 18
        let spread = CGFloat.pi / 7
        let p1 = NSPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread))
        let p2 = NSPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread))
        let arrowHead = NSBezierPath()
        arrowHead.lineWidth = 4
        arrowHead.lineCapStyle = .round
        arrowHead.lineJoinStyle = .round
        arrowHead.move(to: p1)
        arrowHead.line(to: to)
        arrowHead.line(to: p2)
        arrowHead.stroke()
    }

    /// All mark points → normalized 0–1 top-left (flip Y from AppKit bottom-left).
    private func normalize(strokes: [[NSPoint]], arrows: [(NSPoint, NSPoint)], size: NSSize) -> [CGPoint] {
        var pts: [NSPoint] = strokes.flatMap { $0 }
        for (a, b) in arrows { pts.append(a); pts.append(b) }
        guard size.width > 0, size.height > 0 else { return [] }
        return pts.map { CGPoint(x: max(0, min(1, $0.x / size.width)),
                                 y: max(0, min(1, 1 - $0.y / size.height))) }
    }
}

// MARK: - DrawPanel
//
// A borderless panel that CAN become key — required so the drawing view receives
// keyDown (Return to send, Esc to cancel). Plain NSPanel/NSWindow returns false from
// canBecomeKey when borderless.
private final class DrawPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - FreehandDrawingView

/// Interactive drawing surface. Plain (bottom-left) NSView, like HandoffSelectionView.
/// Freehand by default; hold Shift while dragging to draw a straight arrow.
final class FreehandDrawingView: NSView {
    private(set) var strokes: [[NSPoint]] = []
    private(set) var arrows:  [(NSPoint, NSPoint)] = []

    private var current: [NSPoint] = []
    private var arrowStart: NSPoint?
    private var arrowEnd: NSPoint?
    private var draggingArrow = false
    private var arrowMode = false   // tappable toggle; ⇧-drag is a momentary shortcut

    var commitOnReturn = true       // standalone shows a Send button; voice-coupled doesn't
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    var hasMarks: Bool { !strokes.isEmpty || !arrows.isEmpty }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // AppKit bottom-left, matches screenshot composite

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        // Toolbar buttons take priority over drawing.
        let b = buttonRects()
        if b.cancel.contains(pt) { onCancel?(); return }
        if commitOnReturn, b.send.contains(pt) {
            if hasMarks { onCommit?() } else { onCancel?() }   // empty → just dismiss
            return
        }
        if b.arrow.contains(pt) { arrowMode.toggle(); needsDisplay = true; return }

        draggingArrow = arrowMode || event.modifierFlags.contains(.shift)
        if draggingArrow {
            arrowStart = pt; arrowEnd = pt
        } else {
            current = [pt]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if draggingArrow { arrowEnd = pt }
        else { current.append(pt) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if draggingArrow {
            if let s = arrowStart, hypot(pt.x - s.x, pt.y - s.y) > 6 { arrows.append((s, pt)) }
            arrowStart = nil; arrowEnd = nil; draggingArrow = false
        } else {
            current.append(pt)
            if current.count > 1 { strokes.append(current) }
            current = []
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:            onCancel?()                       // Escape
        case 36, 76:        if commitOnReturn { onCommit?() } // Return / Enter
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Faint wash so the user knows draw mode is live (and to catch the first click).
        NSColor.black.withAlphaComponent(0.06).setFill()
        bounds.fill()

        let ink = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.95)
        ink.setStroke()

        for stroke in strokes where stroke.count > 1 { strokePath(stroke) }
        if current.count > 1 { strokePath(current) }
        for (a, b) in arrows { arrowPath(from: a, to: b) }
        if let s = arrowStart, let e = arrowEnd { arrowPath(from: s, to: e) }

        drawToolbar()
    }

    private func strokePath(_ pts: [NSPoint]) {
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.line(to: p) }
        path.stroke()
    }

    private func arrowPath(from: NSPoint, to: NSPoint) {
        let shaft = NSBezierPath()
        shaft.lineWidth = 4
        shaft.lineCapStyle = .round
        shaft.move(to: from); shaft.line(to: to)
        shaft.stroke()

        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 18, spread = CGFloat.pi / 7
        let p1 = NSPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread))
        let p2 = NSPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread))
        let h = NSBezierPath()
        h.lineWidth = 4; h.lineCapStyle = .round; h.lineJoinStyle = .round
        h.move(to: p1); h.line(to: to); h.line(to: p2)
        h.stroke()
    }

    // MARK: - Toolbar (clickable, so commit/arrow never depend on the keyboard)

    /// Button frames in view coords (bottom-left). A centered row near the top:
    /// [ Arrow toggle ] [ Cancel ] [ Send ] (Send only when commitOnReturn).
    private func buttonRects() -> (arrow: NSRect, cancel: NSRect, send: NSRect) {
        // Bottom-left, above the Dock — keeps clear of the notch/pill at top center.
        let w: CGFloat = 132, h: CGFloat = 36, gap: CGFloat = 10
        let startX: CGFloat = 28
        let y: CGFloat = 96
        let arrow  = NSRect(x: startX,                 y: y, width: w, height: h)
        let cancel = NSRect(x: startX + (w + gap),     y: y, width: w, height: h)
        let send   = NSRect(x: startX + 2 * (w + gap), y: y, width: w, height: h)
        return (arrow, cancel, send)
    }

    private func drawToolbar() {
        let b = buttonRects()

        // Hint line just above the buttons (left-aligned with them).
        let hint = "Draw to mark" + (commitOnReturn ? "" : " while you talk")
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]
        NSAttributedString(string: hint, attributes: hintAttrs)
            .draw(at: NSPoint(x: b.arrow.minX + 2, y: b.arrow.maxY + 10))
        drawButton(b.arrow,  title: arrowMode ? "↗  Arrow: on" : "✎  Pen",
                   active: arrowMode)
        drawButton(b.cancel, title: "Cancel", active: false)
        if commitOnReturn { drawButton(b.send, title: "Send  ⏎", active: true) }
    }

    private func drawButton(_ rect: NSRect, title: String, active: Bool) {
        let bg = active ? NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 0.9)
                        : NSColor.black.withAlphaComponent(0.6)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        bg.setFill(); pill.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke(); pill.lineWidth = 1; pill.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let s = NSAttributedString(string: title, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }
}
