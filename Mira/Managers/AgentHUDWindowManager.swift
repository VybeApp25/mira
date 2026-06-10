import AppKit
import SwiftUI

// MARK: - AgentHUDPassThroughView
// Root content view that only forwards mouse events to the chip column area.
// Transparent regions fall through to whatever is below (other apps, desktop).
// Mirrors HeyClicky's CodexHUDInteractiveRectPreferenceKey approach.

final class AgentHUDPassThroughView: NSView {
    // Retained but unused for coordinate gating — kept for API compatibility.
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Ask the view hierarchy if anything wants this point.
        // SwiftUI views that have no gesture handler return nil from their hit test,
        // so transparent panel regions naturally pass through to what's below.
        let candidate = super.hitTest(point)
        // Only swallow events that an actual sub-view claims (not just this container).
        return candidate === self ? nil : candidate
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - AgentHUDInteractiveRectKey
// SwiftUI PreferenceKey that bubbles chip bounds up so we can restrict hit-testing.

struct AgentHUDInteractiveRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        value = value == .zero ? n : value.union(n)
    }
}

// MARK: - AgentHUDWindowManager
// One NSPanel per display, pinned to the right edge of the visible frame.
// Chip views live inside this panel and observe AgentJobStore reactively.

@MainActor
final class AgentHUDWindowManager {
    static let shared = AgentHUDWindowManager()

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var passThroughViews: [CGDirectDisplayID: AgentHUDPassThroughView] = [:]
    private var displayObserver: Any?
    private var running = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        buildPanelsForAllScreens()
        watchDisplayChanges()
    }

    func stop() {
        running = false
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        passThroughViews.removeAll()
        if let obs = displayObserver {
            NotificationCenter.default.removeObserver(obs)
            displayObserver = nil
        }
    }

    // MARK: - Panel construction

    private func buildPanelsForAllScreens() {
        for screen in NSScreen.screens { buildPanel(for: screen) }
    }

    private func buildPanel(for screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID ?? CGMainDisplayID()

        let visible  = screen.visibleFrame
        let panelW:  CGFloat = 304
        let panelFrame = CGRect(
            x: visible.maxX - panelW - 8,
            y: visible.minY,
            width: panelW,
            height: visible.height
        )

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level                = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        panel.backgroundColor      = .clear
        panel.isOpaque             = false
        panel.hasShadow            = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        // Pass-through container (only chips receive events)
        let passThrough = AgentHUDPassThroughView()
        passThrough.frame = CGRect(origin: .zero, size: panelFrame.size)

        // SwiftUI column view
        let windowFrame = panelFrame
        let columnView = AgentHUDColumnView()
            .onPreferenceChange(AgentHUDInteractiveRectKey.self) { [weak passThrough] screenRect in
                // Convert screen coords → window-local coords
                let local = CGRect(
                    x: screenRect.minX - windowFrame.minX,
                    y: screenRect.minY - windowFrame.minY,
                    width: screenRect.width,
                    height: screenRect.height
                )
                passThrough?.interactiveRect = local
            }

        let host = NSHostingView(rootView: columnView)
        host.frame = CGRect(origin: .zero, size: panelFrame.size)
        passThrough.addSubview(host)
        panel.contentView = passThrough

        panel.setFrame(panelFrame, display: false)
        panel.orderFrontRegardless()

        panels[displayID]        = panel
        passThroughViews[displayID] = passThrough
    }

    private func rebuildPanels() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        passThroughViews.removeAll()
        buildPanelsForAllScreens()
    }

    // MARK: - Display changes

    private func watchDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildPanels() }
        }
    }
}
