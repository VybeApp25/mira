import Cocoa
import SwiftUI

@MainActor
class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover    = NSPopover()
    private let state:     MiraState
    private let overlay  = OverlayWindowController()
    private let capture  = ScreenCaptureService()
    private let voice    = VoiceService()

    init(miraState: MiraState = MiraState()) {
        self.state = miraState
        super.init()
        setupButton()
        setupPopover()
        setupMenu()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let btn = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Mira")
        img?.isTemplate = true
        btn.image = img
        btn.title = ""
        btn.imagePosition = .imageLeft
        btn.action = #selector(handleClick)
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        btn.target = self
    }

    private func setupPopover() {
        let panel = MiraPanel(state: state, overlay: overlay, capture: capture, voice: voice)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status header
        let header = NSMenuItem(title: "Mira is running", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // ── Keyboard shortcut items ───────────────────────────────────────────
        // NSMenu key equivalents work globally for background apps with NO
        // Accessibility permission required — AppKit handles the interception.

        let voiceItem = NSMenuItem(
            title:        "Talk to Mira",
            action:       #selector(shortcutVoice),
            keyEquivalent: "v"               // ⌃⌥ V
        )
        voiceItem.keyEquivalentModifierMask = [.control, .option]
        voiceItem.target = self
        menu.addItem(voiceItem)

        let textItem = NSMenuItem(
            title:        "Text Mira",
            action:       #selector(shortcutText),
            keyEquivalent: "t"               // ⌃⌥ T
        )
        textItem.keyEquivalentModifierMask = [.control, .option]
        textItem.target = self
        menu.addItem(textItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Chat Panel", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Mira", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        contextMenu = menu
    }

    private var contextMenu: NSMenu?

    // MARK: - Shortcut actions (fired by key equivalents globally)

    @objc private func shortcutVoice() {
        NotificationCenter.default.post(name: .miraActivateVoice, object: nil)
    }

    @objc private func shortcutText() {
        NotificationCenter.default.post(name: .miraActivateText, object: nil)
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            if let btn = statusItem.button, let menu = contextMenu {
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: btn.bounds.height + 4),
                           in: btn)
            }
        } else {
            togglePopover()
        }
    }

    @objc private func openPanel() { togglePopover() }

    private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
