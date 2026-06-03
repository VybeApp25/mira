import Cocoa
import SwiftUI

@MainActor
class OverlayWindowController: ObservableObject {
    private var window: NSWindow?
    private var dismissTimer: DispatchWorkItem?

    func show(at point: CGPoint, label: String = "Here") {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        if window == nil {
            let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.backgroundColor = .clear
            win.isOpaque = false
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.hasShadow = false
            window = win
        }

        let view = PointerOverlay(point: point, label: label, screenSize: frame.size)
        window?.contentView = NSHostingView(rootView: view)
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()

        dismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    func hide() {
        dismissTimer?.cancel()
        window?.orderOut(nil)
    }
}
