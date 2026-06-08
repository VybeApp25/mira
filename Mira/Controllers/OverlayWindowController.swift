import Cocoa
import SwiftUI

class OverlayWindowController: ObservableObject {
    private var window: NSWindow?
    private var dismissTimer: DispatchWorkItem?

    // MARK: - Point overlay (original)

    func show(at point: CGPoint, label: String = "Here") {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        makeWindowIfNeeded(frame: screenFrame)

        let view = PointerOverlay(point: point, label: label, screenSize: screenFrame.size)
        window?.contentView = NSHostingView(rootView: view)
        window?.setFrame(screenFrame, display: true)
        window?.orderFrontRegardless()
        scheduleDismiss(after: 6)
    }

    // MARK: - Guidance overlay

    func showGuidance(_ guidanceFrame: GuidanceFrame) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        makeWindowIfNeeded(frame: screenFrame)

        let view = GuidanceOverlayView(guidanceFrame: guidanceFrame, screenSize: screenFrame.size)
        window?.contentView = NSHostingView(rootView: view)
        window?.setFrame(screenFrame, display: true)
        window?.orderFrontRegardless()
        scheduleDismiss(after: 10)
    }

    // MARK: - Test path (Deliverable 2)

    func showTest() {
        guard let screen = NSScreen.main else { return }
        let sz = screen.frame.size
        let rect = CGRect(
            x: sz.width / 2 - 150,
            y: sz.height / 2 - 50,
            width: 300,
            height: 100
        )
        let target = GuidanceTarget(
            id: UUID(),
            rect: rect,
            confidence: 1.0,
            label: "Test Target",
            explanation: "Overlay renderer verified — positioning and fade-in are working correctly."
        )
        showGuidance(GuidanceFrame(timestamp: .now, targets: [target]))
    }

    func hide() {
        dismissTimer?.cancel()
        window?.orderOut(nil)
    }

    // MARK: - Private

    private func makeWindowIfNeeded(frame: CGRect) {
        guard window == nil else { return }
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.hasShadow = false
        window = win
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
