import Cocoa
import SwiftUI

// MARK: - Selection NSView

// Full-screen interactive overlay for region selection.
// Dims everything outside the dragged rectangle; border + dimensions on selection.
final class HandoffSelectionView: NSView {
    var startPt:   NSPoint?
    var currentPt: NSPoint?
    var onSelect: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPt   = convert(event.locationInWindow, from: nil)
        currentPt = startPt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPt = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPt = convert(event.locationInWindow, from: nil)
        guard let s = startPt, let c = currentPt,
              abs(c.x - s.x) > 8, abs(c.y - s.y) > 8 else {
            onCancel?()
            return
        }
        let rect = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                          width: abs(c.x - s.x), height: abs(c.y - s.y))
        onSelect?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.01).setFill()
        bounds.fill()

        guard let s = startPt, let c = currentPt else {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            return
        }

        let sel = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                         width: abs(c.x - s.x), height: abs(c.y - s.y))

        // Dim the 4 panels around the selection
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.minX, y: sel.maxY,  width: bounds.width, height: bounds.maxY - sel.maxY).fill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: sel.minY - bounds.minY).fill()
        NSRect(x: bounds.minX, y: sel.minY, width: sel.minX - bounds.minX, height: sel.height).fill()
        NSRect(x: sel.maxX,   y: sel.minY, width: bounds.maxX - sel.maxX, height: sel.height).fill()

        // Selection border
        let path = NSBezierPath(rect: sel)
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2
        path.stroke()

        // Dimension label
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: sel.minX + 4, y: sel.maxY + 6))
    }
}

// MARK: - HandoffService

struct HandoffResult {
    let image:  NSImage
    let rect:   NSRect   // in AppKit (bottom-left) screen coordinates
    let prompt: String
}

@MainActor
final class HandoffService {
    static let shared = HandoffService()
    private init() {}

    private var overlayPanel: NSPanel?

    // Show the region-select overlay. Completion fires with the cropped image and rect.
    func beginRegionSelect(prompt: String = "What is in this region?",
                           completion: @escaping (HandoffResult) -> Void) {
        guard let screen = NSScreen.main else { return }
        cancelIfNeeded()

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.backgroundColor = .clear
        panel.isOpaque        = false
        panel.hasShadow       = false
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = HandoffSelectionView()
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = view

        view.onCancel = { [weak self] in
            self?.cancelIfNeeded()
            NSCursor.arrow.set()
        }

        view.onSelect = { [weak self] rect in
            panel.orderOut(nil)
            self?.overlayPanel = nil
            NSCursor.arrow.set()

            Task {
                let img = await ComputerUseService.shared.screenshotCropped(to: rect)
                    ?? NSImage()
                completion(HandoffResult(image: img, rect: rect, prompt: prompt))
            }
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSCursor.crosshair.set()
        overlayPanel = panel
    }

    func cancelIfNeeded() {
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
    }
}
