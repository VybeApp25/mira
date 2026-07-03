import AppKit
import Combine

// MARK: - NotchDropZoneController
//
// A small NSPanel that catches Finder file drags aimed at the notch, so the user
// can drop a file "into the notch" to stash it on the Shelf — even while the main
// island panel is collapsed (that panel is click-through when collapsed, so it can
// never see a drag on its own).
//
// Three hard-won details from getting this to actually fire:
//
//  1. POSITION: the catch area hangs just BELOW the physical notch, in normal
//     screen space — NOT inside the notch / menu-bar strip. App windows in the
//     menu-bar strip don't reliably receive cross-process Finder drags (that strip
//     is system-owned); TheBoringNotch's shelf drop works for the same reason —
//     its catch area hangs below the notch too.
//
//  2. INTERACTIVITY vs. clicks: to see a drag the window must NOT ignore mouse
//     events. But when the island is EXPANDED its nav bar renders right here, so a
//     non-pass-through catcher would eat nav-bar clicks. We therefore go
//     pass-through when the island is expanded — EXCEPT while a drag is in flight
//     (there are no clicks to protect during a drag, and we must stay interactive
//     to receive the drop). See `isDragActive`.
//
//  3. DON'T self-disable mid-drag: entering the zone triggers the island to expand,
//     which would otherwise flip us pass-through before the user releases — losing
//     the drop. `isDragActive` pins us interactive until the drag ends.

@MainActor
final class NotchDropZoneController {
    private var panel: NSPanel?
    private let geometry: NotchGeometry
    private let animController: AnimationController
    private var cancellable: AnyCancellable?

    private var isExpanded  = false
    private var isDragActive = false

    init(geometry: NotchGeometry, animController: AnimationController) {
        self.geometry = geometry
        self.animController = animController
    }

    func install() {
        guard panel == nil else { return }
        let rect = dropRect()
        let view = NotchDropZoneView(frame: NSRect(origin: .zero, size: rect.size))
        view.autoresizingMask = [.width, .height]
        view.onDragActiveChanged = { [weak self] active in
            guard let self else { return }
            self.isDragActive = active
            // While a drag is in flight, grow the catch window to cover the whole
            // open panel so the user can release ANYWHERE in the open notch — not
            // just the thin 44pt strip they first entered. Shrink back when done.
            self.panel?.setFrame(active ? self.expandedDropRect() : self.dropRect(), display: false)
            self.updatePassThrough()
        }
        let p = NSPanel(
            contentRect: rect,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        // One level above the island panel so the island (which re-asserts itself
        // to the front of its own level whenever it expands via makeKey) can never
        // shadow this catcher.
        p.level                       = NSWindow.Level(rawValue: MiraIslandWindowManager.islandLevel.rawValue + 1)
        p.backgroundColor             = .clear
        p.isOpaque                    = false
        p.hasShadow                   = false
        p.ignoresMouseEvents          = false   // collapsed default: catch drags
        p.isMovableByWindowBackground = false
        p.sharingType                 = .none
        p.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        p.contentView = view
        p.orderFrontRegardless()
        panel = p

        cancellable = animController.$state.sink { [weak self] state in
            MainActor.assumeIsolated {
                self?.isExpanded = (state == .expanded)
                self?.updatePassThrough()
            }
        }

        MiraDebugLog.log("[DropZone] installed frame=\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)) level=\(p.level.rawValue)")
    }

    /// Pass-through only when expanded AND no drag is happening. During a drag we
    /// stay interactive so the drop lands here regardless of expand state.
    private func updatePassThrough() {
        let passThrough = isExpanded && !isDragActive
        panel?.ignoresMouseEvents = passThrough
        MiraDebugLog.log("[DropZone] passThrough=\(passThrough) (expanded=\(isExpanded) dragActive=\(isDragActive))")
    }

    /// Catch strip that hangs BELOW the notch's bottom edge, in deliverable screen
    /// space. Kept near the notch width so, when expanded, it only overlaps the
    /// center of the nav bar.
    private func dropRect() -> CGRect {
        let padX: CGFloat = 20
        let dropHeight: CGFloat = 44
        let nc = geometry.notchCenter          // bottom-center of the notch, Cocoa coords
        let w  = geometry.notchWidth + padX * 2
        return CGRect(x: nc.x - w / 2, y: nc.y - dropHeight, width: w, height: dropHeight)
    }

    /// Covers the full expanded panel footprint so a drop can land anywhere in the
    /// open notch. Used only while a drag is active (see onDragActiveChanged).
    private func expandedDropRect() -> CGRect {
        let w: CGFloat = AnimationController.expandedW + 40
        let h: CGFloat = geometry.notchHeight + AnimationController.expandedTallH + 20
        let s = geometry.screen
        return CGRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h)
    }
}

// MARK: - Drop target view

@MainActor
private final class NotchDropZoneView: NSView {
    /// Called with true when a drag enters this view, false when it exits or drops.
    var onDragActiveChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // Layer-backed hit area — bounds are always drag-hit-testable regardless of
    // transparency. Faint tint only while a drag is over it, for feedback.
    private func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let canRead = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        MiraDebugLog.log("[DropZone] draggingEntered canReadURL=\(canRead)")
        guard canRead else { return [] }
        onDragActiveChanged?(true)      // pin interactive before the island expands
        setHighlighted(true)
        NotificationCenter.default.post(name: .miraDragEnteredNotch, object: nil)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Only clear the tint here. Do NOT reset drag state / shrink the window on
        // exit — growing the window on entry can momentarily trip an exit/enter, and
        // shrinking here would undo the grow mid-drag. The definitive reset happens
        // in draggingEnded (session over) and performDragOperation (dropped here).
        MiraDebugLog.log("[DropZone] draggingExited")
        setHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MiraDebugLog.log("[DropZone] draggingEnded")
        setHighlighted(false)
        onDragActiveChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        MiraDebugLog.log("[DropZone] performDragOperation urls=\(urls.count) \(urls.map { $0.lastPathComponent })")
        onDragActiveChanged?(false)
        guard !urls.isEmpty else { return false }
        FileShelfService.shared.add(urls)
        // Make sure the island is open on the Shelf tab so the drop is visible.
        NotificationCenter.default.post(name: .miraDragEnteredNotch, object: nil)
        return true
    }
}
