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

        // Always-on continuous voice — toggles a hands-free session that lives in the
        // CLOSED notch (listening/speaking shown in the pill). Checkmark reflects state.
        let alwaysOn = NSMenuItem(title: "Always-on voice",
                                  action: #selector(toggleAlwaysOn), keyEquivalent: "")
        alwaysOn.target = self
        menu.addItem(alwaysOn)
        self.alwaysOnItem = alwaysOn

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Chat Panel", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        #if DEBUG
        let axProbe = NSMenuItem(title: "Run AX Background Actuation Probe",
                                 action: #selector(runAXActuationProbe), keyEquivalent: "")
        axProbe.target = self
        menu.addItem(axProbe)

        let bgTask = NSMenuItem(title: "Run Background Task (notify + speak)",
                                action: #selector(runBackgroundTaskDemo), keyEquivalent: "")
        bgTask.target = self
        menu.addItem(bgTask)

        let routed = NSMenuItem(title: "Run Routed Task (router + announce)",
                                action: #selector(runRoutedTaskDemo), keyEquivalent: "")
        routed.target = self
        menu.addItem(routed)
        menu.addItem(.separator())
        #endif

        let quit = NSMenuItem(title: "Quit Mira", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        contextMenu = menu
    }

    private var contextMenu: NSMenu?
    private var alwaysOnItem: NSMenuItem?

    // MARK: - Shortcut actions (fired by key equivalents globally)

    @objc private func shortcutVoice() {
        NotificationCenter.default.post(name: .miraActivateVoice, object: nil)
    }

    @objc private func shortcutText() {
        NotificationCenter.default.post(name: .miraActivateText, object: nil)
    }

    @objc private func toggleAlwaysOn() {
        NotificationCenter.default.post(name: .miraToggleAlwaysOn, object: nil)
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            if let btn = statusItem.button, let menu = contextMenu {
                MainActor.assumeIsolated {
                    alwaysOnItem?.state = RealtimeVoiceService.shared.isAlwaysOnActive ? .on : .off
                }
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: btn.bounds.height + 4),
                           in: btn)
            }
        } else {
            togglePopover()
        }
    }

    @objc private func openPanel() { togglePopover() }

    #if DEBUG
    /// DEBUG-only: proves AX background actuation against a real app (default
    /// TextEdit) with zero cursor movement. Open TextEdit with a document, switch
    /// to ANY other app, then run this — the marker text should appear in the
    /// TextEdit document while the pointer never moves and TextEdit never comes
    /// forward. See AXActuationService.runBackgroundActuationProbe.
    @objc private func runAXActuationProbe() {
        let result = AXActuationService.shared.runBackgroundActuationProbe()
        let alert = NSAlert()
        alert.messageText = "AX Background Actuation Probe"
        alert.informativeText = result
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// DEBUG-only: the full autonomous UX in miniature — runs a real actuation
    /// SILENTLY in the background (writes into TextEdit, no cursor, no focus
    /// steal), then Mira posts a notification AND speaks "Done." Open TextEdit
    /// with a document, switch to another app, then run this: the note appears,
    /// the cursor never moves, a notification arrives, and Mira says it's done.
    @objc private func runBackgroundTaskDemo() {
        Task { @MainActor in
            TaskAnnouncer.shared.run(task: "write a note in TextEdit") {
                _ = try AXActuationService.shared.setTextValue(
                    "Mira did this in the background ✅",
                    inBundleID: "com.apple.TextEdit")
            }
        }
    }

    /// DEBUG-only: drives a task through the full integrated front door —
    /// ComputerUseOrchestrator.perform routes via ActuationRouter (AX background
    /// vs cursor vs vision), counts the run in TaskRunLedger, and announces
    /// (notify + speak). Open TextEdit, switch away, then run this.
    @objc private func runRoutedTaskDemo() {
        Task { @MainActor in
            await ComputerUseOrchestrator.shared.perform(
                .setText("Routed by Mira ✅", field: nil),
                on: "com.apple.TextEdit",
                taskDescription: "write a note in TextEdit",
                apiKey: "")   // unused for AX tiers; only vision fallback needs it
            #if DEBUG
            print("[ledger] runs this month: \(TaskRunLedger.shared.runsThisMonth)")
            #endif
        }
    }
    #endif

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
