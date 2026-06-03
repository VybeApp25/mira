import AppKit

/// Polls NSEvent.mouseLocation every 40 ms and fires enter/exit callbacks.
/// Timer-based polling requires no permissions and is immune to macOS
/// Input Monitoring restrictions that silently block NSEvent global monitors.
final class HoverTrackingManager {

    var onEnter: (() -> Void)?
    var onExit:  (() -> Void)?

    private(set) var activationRect: CGRect = .zero
    private var isInside = false
    private var timer:    Timer?

    // MARK: - Lifecycle

    func start(activationRect: CGRect) {
        self.activationRect = activationRect
        // Create without scheduling, then add to main run loop in .common mode
        // so it fires even during scroll/drag tracking loops.
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Update the zone silently — does NOT re-evaluate immediately.
    /// The next timer tick will pick up the new rect, preventing re-entrancy.
    func update(activationRect: CGRect) {
        self.activationRect = activationRect
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isInside = false
    }

    // MARK: - Private

    private func evaluate() {
        let inside = activationRect.contains(NSEvent.mouseLocation)
        if inside && !isInside {
            isInside = true
            onEnter?()
        } else if !inside && isInside {
            isInside = false
            onExit?()
        }
    }
}
