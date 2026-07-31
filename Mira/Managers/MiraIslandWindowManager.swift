import AppKit
import SwiftUI

// MARK: - Island panel subclass

/// Allows the panel to become key (accept keyboard input) when the user clicks
/// a text field, while still not activating the Mira app or stealing focus from
/// whatever app the user was in. canBecomeMain stays false.
private final class IslandPanel: NSPanel {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }

    /// Routes ⌘V/⌘C/⌘X/⌘A/⌘Z to the focused text field ourselves.
    ///
    /// Typing into a field in the notch worked, but PASTING did nothing. Command
    /// keys are key EQUIVALENTS, and macOS dispatches those through the menu bar
    /// of the ACTIVE application. This panel deliberately never activates Mira
    /// (canBecomeMain = false, makeKey without activation) so it doesn't steal
    /// focus — which means ⌘V was being offered to whatever app the user was
    /// actually in, and never reached the field they were typing in.
    ///
    /// Sending the action to nil walks the responder chain from the first
    /// responder, so it lands on the focused NSTextView. This is exactly the
    /// case that made pasting a GitHub token impossible: a value you cannot
    /// reasonably retype by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default:  action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSHostingView subclass that delivers the first mouse-down directly to
/// SwiftUI buttons without requiring a prior focus-click. Default NSPanel
/// behaviour (nonactivatingPanel) swallows the first click; this override
/// ensures buttons like "Save Website" respond on the first tap even when
/// the panel is not yet the key window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Window manager

/// Creates and owns the NSPanel that hosts the Mira island.
/// The panel is sized to the maximum expanded dimensions so SwiftUI can
/// animate freely inside it; the visual pill shape is drawn by SwiftUI.
@MainActor
final class MiraIslandWindowManager {

    // Maximum window dimensions — must contain the expanded island + shadow room.
    static let windowW: CGFloat = 760
    // Tall enough for expandedTallH (500) + notch + shadow margin
    static let windowH: CGFloat = 560

    // Above status bar items + system elements; same tier used by DynamicLake /
    // NotchNook. Extracted so suspend/resume can restore it exactly.
    static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)

    /// When true, the island is allowed to appear in screenshots / screen recordings
    /// (sharingType .readOnly). Default false hides it from capture. Toggled from
    /// Settings → Appearance → "Show in screen recordings" for demo videos.
    static let showInCaptureKey = "mira_show_in_screen_capture"
    static var showInCapture: Bool { UserDefaults.standard.bool(forKey: showInCaptureKey) }

    private var panel: NSPanel?
    private let geometry: NotchGeometry

    // Saved panel state while suspended for a system modal (see suspend/resume).
    private var suspendedIgnoresMouse: Bool?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Lifecycle

    func install(rootView: some View) {
        let p = buildPanel()
        let host = FirstMouseHostingView(rootView: rootView)
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: windowFrame().size)
        p.contentView = host
        p.setFrame(windowFrame(), display: false)
        p.orderFrontRegardless()
        panel = p

        // Apply screen-capture visibility live when the Settings toggle changes.
        NotificationCenter.default.addObserver(
            forName: .miraShowInCaptureChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.sharingType = Self.showInCapture ? .readOnly : .none
            }
        }

        // Step the island out of the way while a system-owned modal (Sparkle's
        // update dialog) is on screen, then restore it. Without this the dialog
        // renders behind the notch overlay and can't be seen or clicked.
        NotificationCenter.default.addObserver(
            forName: .miraSuspendForModal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForModal() }
        }
        NotificationCenter.default.addObserver(
            forName: .miraResumeFromModal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeFromModal() }
        }
    }

    // MARK: - Modal suspend / resume

    /// Drop the panel below normal windows and let clicks pass through, so a
    /// system modal presented on top of the notch is fully visible & clickable.
    private func suspendForModal() {
        guard let panel, suspendedIgnoresMouse == nil else { return }
        suspendedIgnoresMouse = panel.ignoresMouseEvents
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }

    /// Restore the panel's normal overlay level after the modal is dismissed.
    private func resumeFromModal() {
        guard let panel, let priorIgnoresMouse = suspendedIgnoresMouse else { return }
        panel.level = Self.islandLevel
        panel.ignoresMouseEvents = priorIgnoresMouse
        suspendedIgnoresMouse = nil
        panel.orderFrontRegardless()
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
        p.level              = Self.islandLevel
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false    // always off — shadow drawn by SwiftUI to avoid macOS corner rounding
        p.ignoresMouseEvents = true     // pass-through until user hovers
        p.isMovableByWindowBackground = false
        // Exclude the island from screen capture (screenshots, screen recording, SCK)
        // so the notch UI never appears in the user's captures — same trick HeyClicky /
        // DynamicLake use. The notch is Mira's chrome, not the user's content. The user
        // can opt in (e.g. to record a demo) via Settings → Appearance.
        p.sharingType = Self.showInCapture ? .readOnly : .none
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
