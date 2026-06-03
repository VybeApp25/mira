import Cocoa
import SwiftUI

enum MiraTab { case home, agents }

@MainActor
class NotchHUDState: ObservableObject {
    @Published var isExpanded = false
    @Published var selectedTab: MiraTab = .home
}

@MainActor
class NotchHUDController: NSObject {
    private var window: NSWindow?
    private var mouseMonitor: Any?

    private let expandedW: CGFloat = 420
    private let expandedH: CGFloat = 380
    private let pillH: CGFloat    = 36

    let hudState   = NotchHUDState()
    let miraState  = MiraState()
    let taskStore  = AgentTaskStore.shared
    let overlay    = OverlayWindowController()
    let capture    = ScreenCaptureService()
    let voice      = VoiceService()

    private var isExpanded = false

    func setup() {
        guard let screen = NSScreen.main else { return }

        let frame = collapsedFrame(for: screen)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true

        let root = NotchHUDView(
            hudState: hudState,
            miraState: miraState,
            taskStore: taskStore,
            overlay: overlay,
            capture: capture,
            voice: voice
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        win.contentView = hosting

        self.window = win
        win.orderFrontRegardless()
        startMouseTracking()
    }

    // MARK: - Frames

    private func collapsedFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - expandedW / 2,
            y: screen.frame.maxY - pillH,
            width: expandedW,
            height: pillH
        )
    }

    private func expandedFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - expandedW / 2,
            y: screen.frame.maxY - expandedH,
            width: expandedW,
            height: expandedH
        )
    }

    // MARK: - Mouse tracking

    private func startMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateMouse() }
        }
    }

    private func evaluateMouse() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation

        // Expand trigger zone — hover anywhere over the pill
        let trigger = collapsedFrame(for: screen).insetBy(dx: -16, dy: -8)
        let current = isExpanded ? expandedFrame(for: screen) : trigger

        let shouldExpand = trigger.contains(mouse) || (isExpanded && expandedFrame(for: screen).contains(mouse))

        if shouldExpand && !isExpanded { expand(screen: screen) }
        else if !shouldExpand && isExpanded { collapse(screen: screen) }
    }

    private func expand(screen: NSScreen) {
        isExpanded = true
        hudState.isExpanded = true
        window?.ignoresMouseEvents = false

        let target = expandedFrame(for: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().setFrame(target, display: true)
        }
    }

    private func collapse(screen: NSScreen) {
        isExpanded = false
        hudState.isExpanded = false
        window?.ignoresMouseEvents = true

        let target = collapsedFrame(for: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window?.animator().setFrame(target, display: true)
        }
    }
}
