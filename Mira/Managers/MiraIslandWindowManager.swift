import AppKit
import SwiftUI

// MARK: - Island panel subclass

/// Allows the panel to become key (accept keyboard input) when the user clicks
/// a text field, while still not activating the Mira app or stealing focus from
/// whatever app the user was in. canBecomeMain stays false.
private final class IslandPanel: NSPanel {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - Window manager

/// Creates and owns the NSPanel that hosts the Mira island.
/// The panel is sized to the maximum expanded dimensions so SwiftUI can
/// animate freely inside it; the visual pill shape is drawn by SwiftUI.
@MainActor
final class MiraIslandWindowManager {

    // Maximum window dimensions — must contain the expanded island + shadow room.
    static let windowW: CGFloat = 760
    static let windowH: CGFloat = 300

    private var panel: NSPanel?
    private let geometry: NotchGeometry

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Lifecycle

    func install(rootView: some View) {
        let p = buildPanel()
        let host = NSHostingView(rootView: rootView)
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: windowFrame().size)
        p.contentView = host
        p.setFrame(windowFrame(), display: false)
        p.orderFrontRegardless()
        panel = p
    }

    func teardown() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Mouse event pass-through

    /// Set to false (pass-through) when collapsed; true (interactive) when expanded.
    func setInteractive(_ interactive: Bool) {
        panel?.ignoresMouseEvents = !interactive
        if interactive {
            // Make the panel key so text fields inside it can receive keyboard input.
            // Using makeKeyAndOrderFront would steal app focus; makeKey() alone is enough.
            panel?.makeKey()
        }
        // hasShadow stays false always — enabling it causes macOS to auto-round the
        // window corners at the compositor level, fighting our flat-top IslandShape.
        // Shadow is drawn by SwiftUI's .shadow() modifier on the pill instead.
    }

    // MARK: - Private

    private func buildPanel() -> NSPanel {
        let frame = windowFrame()
        let p = IslandPanel(
            contentRect: frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        // Level: above status bar items + system elements; same tier used by DynamicLake / NotchNook.
        p.level              = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false    // always off — shadow drawn by SwiftUI to avoid macOS corner rounding
        p.ignoresMouseEvents = true     // pass-through until user hovers
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,   // visible above fullscreen apps
        ]
        return p
    }

    private func windowFrame() -> CGRect {
        let s = geometry.screen
        return CGRect(
            x:      s.frame.midX - Self.windowW / 2,
            // Top of window flush with top of screen; island hangs downward from notch.
            y:      s.frame.maxY - Self.windowH,
            width:  Self.windowW,
            height: Self.windowH
        )
    }
}
