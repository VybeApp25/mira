import AppKit
import SwiftUI

// MARK: - Cursor states (matches HeyClicky's BlueCursorView states)

enum MiraCursorState: Equatable {
    case arrow       // default blue arrow
    case thinking    // spinner ring (processing)
    case stop        // square stop icon (interruptable)
    case listening   // waveform bars (voice active)
}

// MARK: - Shared overlay model

@MainActor
final class OverlayModel: ObservableObject {
    @Published var cursorPosition: CGPoint = .zero
    @Published var cursorState: MiraCursorState = .arrow
    @Published var bubbleWords: [BubbleWordToken] = []
    @Published var showBubble: Bool = false
}

struct BubbleWordToken: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - OverlayWindowManager
// HeyClicky's OverlayWindowManager equivalent: one full-screen transparent
// NSWindow per display. Both cursor and bubble live inside the same window,
// so they are always in sync and never suffer the separate-panel drift issue.

@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    let model = OverlayModel()

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var trackingTimer: Timer?
    private var displayObserver: Any?
    private var active = false
    private var bubbleHideTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func activate() {
        guard !active else { return }
        active = true
        CGDisplayHideCursor(kCGNullDirectDisplay)
        buildOverlaysForAllScreens()
        startTracking()
        watchDisplayChanges()
    }

    func deactivate() {
        guard active else { return }
        active = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        bubbleHideTask?.cancel()
        if let obs = displayObserver {
            NotificationCenter.default.removeObserver(obs)
            displayObserver = nil
        }
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        CGDisplayShowCursor(kCGNullDirectDisplay)
    }

    // MARK: - Bubble API (called by CursorBubbleService facade)

    func showBubble() {
        bubbleHideTask?.cancel()
        model.bubbleWords = []
        model.showBubble = true
    }

    func appendBubbleToken(_ token: String) {
        let words = token.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for w in words {
            model.bubbleWords.append(BubbleWordToken(text: w + " "))
        }
    }

    func finishBubble() {
        bubbleHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    self?.model.showBubble = false
                }
            }
        }
    }

    func hideBubble() {
        bubbleHideTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            model.showBubble = false
        }
    }

    func setCursorState(_ state: MiraCursorState) {
        model.cursorState = state
    }

    // MARK: - Window construction

    private func buildOverlaysForAllScreens() {
        for screen in NSScreen.screens {
            buildOverlay(for: screen)
        }
    }

    private func buildOverlay(for screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? CGMainDisplayID()

        let win = NSWindow(
            contentRect: screen.frame,
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        win.level                = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        win.backgroundColor      = .clear
        win.isOpaque             = false
        win.hasShadow            = false
        win.ignoresMouseEvents   = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = OverlayContentView(model: model, screenFrame: screen.frame)
        let host    = NSHostingView(rootView: content)
        host.frame  = CGRect(origin: .zero, size: screen.frame.size)
        win.contentView = host
        win.setFrame(screen.frame, display: false)
        win.orderFrontRegardless()

        overlayWindows[displayID] = win
    }

    private func rebuildOverlays() {
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        buildOverlaysForAllScreens()
    }

    // MARK: - 60fps cursor tracking

    private func startTracking() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.cursorPosition = NSEvent.mouseLocation
            }
        }
        RunLoop.main.add(t, forMode: .common)
        trackingTimer = t
    }

    // MARK: - Display change handling

    private func watchDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildOverlays() }
        }
    }
}

// MARK: - Thin facade so AppDelegate doesn't need to change

@MainActor
final class MiraCursorManager {
    static let shared = MiraCursorManager()
    private init() {}
    func activate()   { OverlayWindowManager.shared.activate() }
    func deactivate() { OverlayWindowManager.shared.deactivate() }
}

// MARK: - OverlayContentView
// Full-screen SwiftUI root. Both BlueCursorView and CursorMessageBubbleView
// live here so they share the same coordinate space — no window sync drift.

struct OverlayContentView: View {
    @ObservedObject var model: OverlayModel
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            Color.clear

            let localPos = toLocal(model.cursorPosition)

            // ── Blue cursor ──────────────────────────────────────────────
            // .position() centers the view on localPos, but the arrow tip sits at
            // ~(3, 3) within the 32×32 frame, so offset center by (13, 13) to
            // put the tip exactly at the cursor hot-spot.
            BlueCursorView(state: model.cursorState)
                .position(x: localPos.x + 13, y: localPos.y + 13)

            // ── Streaming bubble ─────────────────────────────────────────
            if model.showBubble && !model.bubbleWords.isEmpty {
                CursorMessageBubbleView(
                    words: model.bubbleWords,
                    tailOnLeft: bubbleTailOnLeft(cursor: localPos)
                )
                .position(bubbleCenter(cursor: localPos))
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.88,
                                      anchor: bubbleTailOnLeft(cursor: localPos) ? .leading : .trailing)
                        .combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.spring(response: 0.22, dampingFraction: 0.80), value: model.showBubble)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .animation(.spring(response: 0.22, dampingFraction: 0.80), value: model.showBubble)
    }

    // AppKit y=0 bottom → SwiftUI y=0 top, relative to this screen's origin
    private func toLocal(_ pt: CGPoint) -> CGPoint {
        CGPoint(
            x: pt.x - screenFrame.minX,
            y: screenFrame.height - (pt.y - screenFrame.minY)
        )
    }

    // Bubble anchors to the right of cursor; flips left near the right edge
    private func bubbleTailOnLeft(cursor: CGPoint) -> Bool {
        let rightEdge = cursor.x + 22 + 260
        return rightEdge < screenFrame.width - 16
    }

    private func bubbleCenter(cursor: CGPoint) -> CGPoint {
        let bubbleW: CGFloat = 260
        let offset:  CGFloat = 22
        if bubbleTailOnLeft(cursor: cursor) {
            return CGPoint(x: cursor.x + offset + bubbleW / 2, y: cursor.y)
        } else {
            return CGPoint(x: cursor.x - offset - bubbleW / 2, y: cursor.y)
        }
    }
}

// MARK: - BlueCursorView
// Matches HeyClicky's BlueCursorView: a custom blue arrow cursor with state sub-views.

struct BlueCursorView: View {
    let state: MiraCursorState

    private let blue = Color(red: 0.18, green: 0.56, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Arrow — 32×32, tip at (3, 3)
            BlueArrowShape()
                .fill(blue)
                .frame(width: 32, height: 32)
                .overlay(
                    BlueArrowShape()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                        .frame(width: 32, height: 32)
                )
                .shadow(color: blue.opacity(0.65), radius: 8, x: 0, y: 0)

            // State indicator sits at the base of the arrow shaft
            stateIndicator
                .offset(x: 20, y: 20)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch state {
        case .arrow:
            EmptyView()
        case .thinking:
            BlueCursorSpinnerView(color: blue)
        case .stop:
            BlueCursorStopView(color: blue)
        case .listening:
            BlueCursorWaveformView(color: blue)
        }
    }
}

// Arrow path: cursor pointing up-left, tip at (3, 3) within the 32×32 frame.
// The offsetting in OverlayContentView puts this tip at the actual mouse position.
private struct BlueArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 32.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var p = Path()
        p.move(to:    pt(3,   3))    // tip
        p.addLine(to: pt(3,   26))
        p.addLine(to: pt(8,   20))
        p.addLine(to: pt(13,  30))
        p.addLine(to: pt(16,  28.5))
        p.addLine(to: pt(11,  18))
        p.addLine(to: pt(18,  18))
        p.closeSubpath()
        return p
    }
}

// Spinner ring (HeyClicky's BlueCursorSpinnerView)
private struct BlueCursorSpinnerView: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// Stop square (HeyClicky's BlueCursorStopIconView)
private struct BlueCursorStopView: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

// Waveform bars (HeyClicky's BlueCursorWaveformView)
private struct BlueCursorWaveformView: View {
    let color: Color
    @State private var phase: Bool = false

    private let heights: [CGFloat] = [4, 8, 12, 8, 4]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2, height: phase ? heights[i] : heights[(i + 2) % 5])
                    .animation(
                        .easeInOut(duration: 0.4).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.07),
                        value: phase
                    )
            }
        }
        .frame(height: 14)
        .onAppear { phase = true }
    }
}
