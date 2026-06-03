import Cocoa
import SwiftUI

@MainActor
class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let state = MiraState()
    private let overlay = OverlayWindowController()
    private let capture = ScreenCaptureService()
    private let voice = VoiceService()

    override init() {
        super.init()

        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Mira")
            img?.isTemplate = true
            btn.image = img
            btn.action = #selector(toggle)
            btn.target = self
        }

        let panel = MiraPanel(state: state, overlay: overlay, capture: capture, voice: voice)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
    }

    @objc private func toggle() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
