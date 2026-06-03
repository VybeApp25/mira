import Cocoa
import SwiftUI

enum MiraTab { case home, agents }

class NotchHUDState: ObservableObject {
    @Published var isExpanded = false
    @Published var selectedTab: MiraTab = .home
}

class NotchHUDController: NSObject {
    private var window: NSWindow?
    private var mouseMonitor: Any?

    let hudState   = NotchHUDState()
    let miraState  = MiraState()
    let taskStore  = AgentTaskStore.shared
    let overlay    = OverlayWindowController()
    let capture    = ScreenCaptureService()
    let voice      = VoiceService()

    private var isExpanded = false

    private let expandedW: CGFloat = 420
    private let expandedH: CGFloat = 380
    private let pillH:     CGFloat = 36

    func setup() {
        guard let screen = NSScreen.main else { return }

        let frame = collapsedFrame(for: screen)
        print("[Mira] Creating window at: \(frame)")

        let win = NSWindow(
            contentRect: frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        win.backgroundColor   = NSColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        win.isOpaque          = true
        win.hasShadow         = true
        win.level             = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true

        let root = NotchHUDView(
            hudState:  hudState,
            miraState: miraState,
            taskStore: taskStore,
            overlay:   overlay,
            capture:   capture,
            voice:     voice
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        win.contentView = hosting

        self.window = win
        win.orderFrontRegardless()

        startMouseTracking()
    }

    // MARK: - Frames (NSScreen bottom-left origin)

    private func collapsedFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x:      screen.frame.midX - expandedW / 2,
            y:      screen.frame.maxY - pillH,
            width:  expandedW,
            height: pillH
        )
    }

    private func expandedFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x:      screen.frame.midX - expandedW / 2,
            y:      screen.frame.maxY - expandedH,
            width:  expandedW,
            height: expandedH
        )
    }

    // MARK: - Mouse tracking

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluateMouse() }
        }
    }

    private func evaluateMouse() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let trigger = collapsedFrame(for: screen).insetBy(dx: -20, dy: -8)
        let shouldExpand = trigger.contains(mouse) || (isExpanded && expandedFrame(for: screen).contains(mouse))

        if shouldExpand && !isExpanded { expand(screen: screen) }
        else if !shouldExpand && isExpanded { collapse(screen: screen) }
    }

    private func expand(screen: NSScreen) {
        isExpanded = true
        hudState.isExpanded = true
        window?.ignoresMouseEvents = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().setFrame(expandedFrame(for: screen), display: true)
        }
    }

    private func collapse(screen: NSScreen) {
        isExpanded = false
        hudState.isExpanded = false
        window?.ignoresMouseEvents = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window?.animator().setFrame(collapsedFrame(for: screen), display: true)
        }
    }
}
