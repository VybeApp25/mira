import AppKit
import SwiftUI
import Combine

// MARK: - Cursor states (matches HeyClicky's BlueCursorView states)

enum MiraCursorState: Equatable {
    case arrow       // default blue arrow
    case thinking    // spinner ring (processing)
    case stop        // square stop icon (interruptable)
    case listening   // waveform bars (voice active)
    case speaking    // waveform bars while Mira talks — accent-tinted, animated
}

// MARK: - Shared overlay model

@MainActor
final class OverlayModel: ObservableObject {
    // Only used to anchor the streaming bubble to the real pointer while it is shown.
    // The companion cursor itself is positioned imperatively (see below), never through
    // this — so idle motion never triggers a SwiftUI re-eval.
    @Published var cursorPosition: CGPoint = .zero
    @Published var cursorState: MiraCursorState = .arrow
    @Published var showBubble: Bool = false
    @Published var bubbleWords: [BubbleWordToken] = []
}

struct BubbleWordToken: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - OverlayWindowManager
//
// HeyClicky-exact cursor implementation — verified against HeyClicky's live behavior
// and its binary (which links NSCursor + cursor-rect selectors and links NEITHER
// CGDisplayHideCursor nor any cursor-tracking event tap; its dedicated-thread tap is
// the Escape-interrupt tap, not a cursor tracker).
//
// The key insight, confirmed on screen: HeyClicky NEVER hides the real system cursor.
// Its blue cursor is a DETACHED COMPANION — a drawn element that trails the real pointer
// at a fixed offset (~+30, +26 pt, down-right), living in a click-through overlay. That
// is exactly why it feels native: you still aim and click with the real, hardware-drawn
// system cursor (which cannot lag), and the blue companion sits off to the side where any
// tracking latency reads as natural "following", never as a laggy pointer. (This is the
// meaning of HeyClicky's `DetachedCursorClickCatcherView`.)
//
// Mira's old design did the opposite — it HID the real cursor and pinned a fake one to
// the pointer tip, so every stutter landed on the exact thing you were aiming with. This
// rewrite drops that entirely:
//   • The system cursor is never hidden or replaced — no CGDisplayHideCursor, no
//     SetsCursorInBackground SPI, no NSCursor override, no failure mode where the pointer
//     goes invisible.
//   • The overlay is fully click-through (ignoresMouseEvents = true), so every click is
//     handled by the real cursor natively — nothing is caught or re-posted.
//   • The blue companion is positioned imperatively (setFrameOrigin) from a passive
//     global mouse monitor — a single layer move per event, no SwiftUI body re-eval. Its
//     detached offset masks the monitor's slight latency.

@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    let model = OverlayModel()

    // The companion sits down-right of the real cursor, matching HeyClicky's offset.
    // AppKit global coords are bottom-left origin, so "down" is negative y.
    private static let companionOffset = CGVector(dx: 30, dy: -26)
    // Where the drawn arrow's tip sits inside its 44×44 host (top-left origin).
    private static let tipInHost = CGPoint(x: 3, y: 3)
    private static let hostSize: CGFloat = 44

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    // The blue companion, one layer-backed host per display, positioned imperatively so a
    // fast flick costs a single setFrameOrigin — never a SwiftUI diff.
    private var cursorHosts: [CGDirectDisplayID: NSHostingView<CompanionCursorView>] = [:]
    private var currentDisplay: CGDirectDisplayID?

    // Passive monitors that feed the companion its position. Global sees events headed to
    // other apps (the common case, since our overlay is click-through and Mira is an
    // accessory app); local covers the pointer moving over Mira's own windows. Neither
    // catches anything — events are observed and pass through untouched.
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var displayObserver: Any?
    private var active = false
    private var paused = false
    private var lastMouseGlobal: CGPoint = .zero

    private var bubbleHideTask: Task<Void, Never>?
    private var voiceStateCancellable: AnyCancellable?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .miraSuspendForModal, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.pauseForModal() } }
        NotificationCenter.default.addObserver(
            forName: .miraResumeFromModal, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resumeFromModal() } }
    }

    // MARK: - Lifecycle

    func activate() {
        guard !active else { return }
        active = true
        buildOverlaysForAllScreens()
        startMouseMonitors()
        positionCompanion(at: NSEvent.mouseLocation)   // place it immediately
        watchDisplayChanges()
        observeVoiceState()
    }

    func deactivate() {
        guard active else { return }
        active = false
        stopMouseMonitors()
        bubbleHideTask?.cancel()
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs); displayObserver = nil }
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        cursorHosts.removeAll()
        currentDisplay = nil
        model.cursorState = .arrow
        // Nothing to restore: we never hid or replaced the system cursor.
    }

    // MARK: - Modal pause / resume
    // A system modal (Sparkle) is up — just drop the companion out of the way. There is
    // no cursor to "give back" since the real one was never taken.

    func pauseForModal() {
        guard active, !paused else { return }
        paused = true
        overlayWindows.values.forEach { $0.orderOut(nil) }
    }

    func resumeFromModal() {
        guard active, paused else { return }
        paused = false
        overlayWindows.values.forEach { $0.orderFrontRegardless() }
        positionCompanion(at: NSEvent.mouseLocation)
    }

    // MARK: - Cursor state (cold path)

    func setCursorState(_ state: MiraCursorState) {
        guard model.cursorState != state else { return }
        withAnimation(.easeInOut(duration: 0.18)) { model.cursorState = state }
    }

    // Speaking → animated accent waveform; otherwise arrow. (Only driver of state today.)
    private func observeVoiceState() {
        voiceStateCancellable = RealtimeVoiceService.shared.$state
            .sink { [weak self] state in
                self?.setCursorState(state == .speaking ? .speaking : .arrow)
            }
    }

    // MARK: - Mouse tracking (hot path)

    private func startMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionCompanion(at: NSEvent.mouseLocation) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.positionCompanion(at: NSEvent.mouseLocation) }
            return event
        }
    }

    private func stopMouseMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor  { NSEvent.removeMonitor(m); localMouseMonitor  = nil }
    }

    /// Place the blue companion offset from the real pointer. `mouse` is AppKit global
    /// (bottom-left origin). No SwiftUI involved — a single layer move.
    private func positionCompanion(at mouse: CGPoint) {
        guard active, !paused else { return }
        lastMouseGlobal = mouse

        let target = CGPoint(x: mouse.x + Self.companionOffset.dx,
                             y: mouse.y + Self.companionOffset.dy)

        // Keep the companion on the display the REAL pointer is on.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? CGMainDisplayID()
        guard let host = cursorHosts[displayID] ?? cursorHosts.first?.value else { return }

        // Hide any companion left showing on another display.
        for (id, other) in cursorHosts where id != displayID && !other.isHidden { other.isHidden = true }
        currentDisplay = displayID

        // Window-local, bottom-left. Align the arrow tip (tipInHost, from the host's
        // top-left) onto `target`: the frame's bottom-left origin therefore sits tipX to
        // the left and (hostSize - tipY) below the tip.
        let wx = target.x - screen.frame.minX
        let wy = target.y - screen.frame.minY
        let origin = CGPoint(x: wx - Self.tipInHost.x,
                             y: wy - (Self.hostSize - Self.tipInHost.y))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.setFrameOrigin(origin)
        CATransaction.commit()
        if host.isHidden { host.isHidden = false }

        // Bubble (cold path) anchors to the real cursor — only sync while shown.
        if model.showBubble { model.cursorPosition = mouse }
    }

    // MARK: - Window construction

    private func buildOverlaysForAllScreens() {
        for screen in NSScreen.screens { buildOverlay(for: screen) }
    }

    private func buildOverlay(for screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? CGMainDisplayID()

        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        // cursorWindow level keeps the companion visible over fullscreen apps/Spaces; the
        // real hardware cursor still draws above it, so the two never fight.
        win.level                = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        win.backgroundColor      = .clear
        win.isOpaque             = false
        win.hasShadow            = false
        win.ignoresMouseEvents   = true          // fully click-through — real cursor clicks
        win.isReleasedWhenClosed = false
        win.collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Container hosts the bubble (SwiftUI, full-screen) plus the imperatively-moved
        // companion cursor above it.
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true

        let bubble = NSHostingView(rootView: OverlayContentView(model: model, screenFrame: screen.frame))
        bubble.frame = container.bounds
        bubble.autoresizingMask = [.width, .height]
        container.addSubview(bubble)

        let companion = NSHostingView(rootView: CompanionCursorView(model: model))
        companion.wantsLayer = true
        companion.frame = CGRect(x: 0, y: 0, width: Self.hostSize, height: Self.hostSize)
        companion.isHidden = true   // shown once positioned on this display
        container.addSubview(companion)
        cursorHosts[displayID] = companion

        win.contentView = container
        win.setFrame(screen.frame, display: false)
        win.orderFrontRegardless()
        overlayWindows[displayID] = win
    }

    private func rebuildOverlays() {
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        cursorHosts.removeAll()
        currentDisplay = nil
        buildOverlaysForAllScreens()
        positionCompanion(at: NSEvent.mouseLocation)
    }

    private func watchDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildOverlays() } }
    }

    // MARK: - Bubble API (called by CursorBubbleService facade)

    func showBubble() {
        bubbleHideTask?.cancel()
        model.bubbleWords = []
        model.cursorPosition = NSEvent.mouseLocation
        model.showBubble = true
    }

    func appendBubbleToken(_ token: String) {
        let words = token.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for w in words { model.bubbleWords.append(BubbleWordToken(text: w + " ")) }
    }

    func finishBubble() {
        bubbleHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)   // HeyClicky-style ~4.5s fade
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
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) { model.showBubble = false }
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

// MARK: - CompanionCursorView
// The detached blue companion. Positioned imperatively (setFrameOrigin), so its only
// reactive dependency is the cursor STATE (arrow/thinking/speaking/…), which changes
// rarely — it never re-renders on movement.
struct CompanionCursorView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        BlueCursorView(state: model.cursorState)
            .frame(width: 44, height: 44, alignment: .topLeading)
    }
}

// MARK: - OverlayContentView (bubble only)
// The custom cursor is drawn by the imperatively-positioned CompanionCursorView, so this
// full-screen SwiftUI root renders only the streaming reply bubble, anchored to the real
// pointer while shown.
struct OverlayContentView: View {
    @ObservedObject var model: OverlayModel
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            Color.clear
            let localPos = toLocal(model.cursorPosition)
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

    private func toLocal(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x - screenFrame.minX,
                y: screenFrame.height - (pt.y - screenFrame.minY))
    }

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

    @ObservedObject private var accentService = AccentColorService.shared
    private var accent: Color { accentService.color }

    private var replacesArrow: Bool { state == .speaking }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BlueArrowShape()
                .fill(accent)
                .frame(width: 32, height: 32)
                .overlay(
                    BlueArrowShape()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                        .frame(width: 32, height: 32)
                )
                .shadow(color: accent.opacity(0.65), radius: 8, x: 0, y: 0)
                .opacity(replacesArrow ? 0 : 1)
                .scaleEffect(replacesArrow ? 0.6 : 1, anchor: .topLeading)

            if replacesArrow {
                BlueCursorWaveformView(color: accent)
                    .offset(x: 1, y: 2)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }

            badgeIndicator.offset(x: 20, y: 20)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.22), value: state)
    }

    @ViewBuilder private var badgeIndicator: some View {
        switch state {
        case .thinking:  BlueCursorSpinnerView(color: accent)
        case .stop:      BlueCursorStopView(color: accent)
        case .listening: BlueCursorWaveformView(color: accent)
        case .arrow, .speaking: EmptyView()
        }
    }
}

// Arrow path: cursor pointing up-left, tip at (3, 3) within the 32×32 frame.
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
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rotation = 360 }
            }
    }
}

private struct BlueCursorStopView: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

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
                        .easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.07),
                        value: phase
                    )
            }
        }
        .frame(height: 14)
        .onAppear { phase = true }
    }
}
