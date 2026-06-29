import AppKit
import SwiftUI
import Combine

// MARK: - Background cursor hiding (private CoreGraphics SPI)
// CGDisplayHideCursor only suppresses the system cursor while the calling app
// is frontmost. Mira is an .accessory app and is never frontmost, so the hide
// is a no-op by default. The private "SetsCursorInBackground" connection
// property lifts that restriction, letting CGDisplayHideCursor work from the
// background. Symbols are resolved via dlsym so a future macOS that drops them
// degrades gracefully (the system cursor simply stays visible) instead of
// failing to launch. The hide is reference-counted on this process's
// WindowServer connection, so if Mira crashes the cursor reappears
// automatically — there is no "stuck invisible cursor" failure mode.
enum BackgroundCursorHider {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias SetPropFn  = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Idempotent — evaluated once. Returns true if the property was set.
    @discardableResult
    static func enable() -> Bool { enabled }

    private static let enabled: Bool = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let connSym = dlsym(handle, "CGSMainConnectionID"),
              let propSym = dlsym(handle, "CGSSetConnectionProperty") else {
            NSLog("[Mira] background cursor hide unavailable (CGS symbols missing)")
            return false
        }
        let mainConn = unsafeBitCast(connSym, to: MainConnFn.self)
        let setProp  = unsafeBitCast(propSym, to: SetPropFn.self)
        let cid = mainConn()
        let err = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        NSLog("[Mira] SetsCursorInBackground => err=%d", err)
        return err == 0
    }()
}

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
    // While paused, the custom cursor is hidden and the real system cursor is
    // restored — used when a system modal (Sparkle's update dialog) is on screen
    // so the user can see the pointer to click it.
    private var paused = false
    // CGDisplayHideCursor/ShowCursor is reference counted: the cursor is only
    // visible once Show has balanced every Hide. The tracking timer issues a Hide
    // every frame, so this count climbs steadily — track it so pauseForModal can
    // fully drain it at once and the real cursor reappears immediately.
    private var hideCount = 0
    private var bubbleHideTask: Task<Void, Never>?
    private var voiceStateCancellable: AnyCancellable?

    private init() {
        // Restore the real cursor whenever a system modal asks the overlays to
        // step aside (see UpdateService / MiraIslandWindowManager). Guarded on
        // `active`, so these are no-ops when the companion isn't running.
        NotificationCenter.default.addObserver(
            forName: .miraSuspendForModal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForModal() }
        }
        NotificationCenter.default.addObserver(
            forName: .miraResumeFromModal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFromModal() }
        }
    }

    // MARK: - Lifecycle

    func activate() {
        guard !active else { return }
        active = true
        // Lift the frontmost-only restriction so the hide below works from this
        // background (.accessory) app — otherwise the system cursor stays visible
        // alongside the custom blue cursor.
        BackgroundCursorHider.enable()
        CGDisplayHideCursor(kCGNullDirectDisplay)
        hideCount += 1
        buildOverlaysForAllScreens()
        startTracking()
        watchDisplayChanges()
        observeVoiceState()
    }

    // Turn the cursor into an animated accent-colored waveform while Mira speaks,
    // back to the arrow otherwise. setCursorState had no driver before this.
    private func observeVoiceState() {
        voiceStateCancellable = RealtimeVoiceService.shared.$state
            .sink { [weak self] state in
                guard let self else { return }
                let next: MiraCursorState = (state == .speaking) ? .speaking : .arrow
                guard self.model.cursorState != next else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.model.cursorState = next
                }
            }
    }

    func deactivate() {
        guard active else { return }
        active = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        bubbleHideTask?.cancel()
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
        model.cursorState = .arrow
        if let obs = displayObserver {
            NotificationCenter.default.removeObserver(obs)
            displayObserver = nil
        }
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        CGDisplayShowCursor(kCGNullDirectDisplay)
    }

    // MARK: - Modal pause / resume

    /// Hide the custom cursor overlay and bring the real system cursor back so
    /// the user can see the pointer to click a system modal.
    func pauseForModal() {
        guard active, !paused else { return }
        paused = true
        overlayWindows.values.forEach { $0.orderOut(nil) }
        // Balance every Hide we've issued in one shot so the real cursor appears
        // instantly. Other apps may have re-shown the cursor (pushing the real
        // count below ours); the extra Show calls below zero are harmless no-ops.
        while hideCount > 0 {
            CGDisplayShowCursor(kCGNullDirectDisplay)
            hideCount -= 1
        }
    }

    /// Restore the custom cursor after the modal is dismissed. The tracking timer
    /// re-asserts the system-cursor hide on its next tick.
    func resumeFromModal() {
        guard active, paused else { return }
        paused = false
        overlayWindows.values.forEach { $0.orderFrontRegardless() }
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
            // HeyClicky fades the cursor bubble ~4–5s after the reply finishes
            try? await Task.sleep(nanoseconds: 4_500_000_000)
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
                guard let self else { return }
                self.model.cursorPosition = NSEvent.mouseLocation
                // Other apps re-show the system cursor whenever the pointer
                // crosses their tracking areas (each sets its own NSCursor), so a
                // one-time hide isn't enough — re-assert it every frame so only
                // the custom cursor remains. The WindowServer drops this process's
                // accumulated hide-count when Mira's connection ends (quit/crash),
                // so there is no stuck-hidden cursor; deactivate() only runs at
                // terminate. (CGCursorIsVisible, which would let us skip redundant
                // calls, is unavailable on modern macOS.)
                // While paused for a system modal, leave the real cursor alone
                // (pauseForModal already drained the hide-count). Otherwise keep
                // re-asserting the hide so only the custom cursor remains.
                if self.active, !self.paused {
                    CGDisplayHideCursor(kCGNullDirectDisplay)
                    self.hideCount += 1
                }
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

    // Follows the user's accent choice — changing the accent in Settings
    // recolors the cursor live.
    @ObservedObject private var accentService = AccentColorService.shared
    private var accent: Color { accentService.color }

    // True for states where the indicator REPLACES the arrow at the pointer
    // hot-spot (a smooth morph), vs. sitting beside it as a small status badge.
    private var replacesArrow: Bool { state == .speaking }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Arrow — 32×32, tip at (3, 3). Cross-fades out while Mira speaks so
            // the waveform takes its place rather than appearing next to it.
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

            // Speaking: the cursor itself becomes an animated accent waveform,
            // centered on the pointer hot-spot (~frame 9,9) — not a side badge.
            if replacesArrow {
                BlueCursorWaveformView(color: accent)
                    .offset(x: 1, y: 2)
                    .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
            }

            // Non-replacing status badges keep their spot at the arrow shaft base.
            badgeIndicator
                .offset(x: 20, y: 20)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.22), value: state)
    }

    @ViewBuilder
    private var badgeIndicator: some View {
        switch state {
        case .thinking:
            BlueCursorSpinnerView(color: accent)
        case .stop:
            BlueCursorStopView(color: accent)
        case .listening:
            BlueCursorWaveformView(color: accent)
        case .arrow, .speaking:
            EmptyView()
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
