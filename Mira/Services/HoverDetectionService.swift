import AppKit

/// Polls NSEvent.mouseLocation every 100 ms and fires `onDwell(position)` after the cursor
/// has stayed within `tolerancePx` of the same point for `dwellSeconds`.
///
/// Timer-based polling requires no permissions and is immune to macOS Input Monitoring
/// restrictions that silently block NSEvent.addGlobalMonitorForEvents callbacks.
@MainActor
final class HoverDetectionService {

    /// Called on the main thread when the cursor has been stable long enough.
    var onDwell: ((CGPoint, Bool) -> Void)?

    /// Set false to suppress dwell while the island is open or voice is active.
    var isEnabled = true

    private var timer:      Timer?
    private var dwellTask:  Task<Void, Never>?
    private var dwellOrigin: CGPoint = CGPoint(x: -9999, y: -9999)

    // Debounce: skip if the same region triggered within `debounceWindowSec`.
    private var lastDwellPos:  CGPoint = CGPoint(x: -9999, y: -9999)
    private var lastDwellDate: Date    = .distantPast

    private let tolerancePx:       CGFloat      = 10
    private let debounceRadiusPx:  CGFloat      = 80
    private let debounceWindowSec: TimeInterval = 30
    private let prefs = HoverPreferences.shared

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelDwell()
    }

    func pause() { isEnabled = false; cancelDwell() }
    func resume() { isEnabled = true }

    // MARK: - Private

    private func handleTick() {
        guard isEnabled, prefs.screenCompanionEnabled else { cancelDwell(); return }

        let pos = NSEvent.mouseLocation

        // Restart dwell timer when cursor moves beyond tolerance.
        guard dist(pos, dwellOrigin) > tolerancePx else { return }
        dwellOrigin = pos
        cancelDwell()

        let dwell  = prefs.sensitivity.dwellSeconds
        let origin = dwellOrigin
        dwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled, self.isEnabled, self.prefs.screenCompanionEnabled else { return }
            self.fireDwell(at: origin)
        }
    }

    private func fireDwell(at pos: CGPoint) {
        let elapsed = Date().timeIntervalSince(lastDwellDate)
        if dist(pos, lastDwellPos) < debounceRadiusPx && elapsed < debounceWindowSec { return }
        lastDwellPos  = pos
        lastDwellDate = Date()

        let optionHeld = NSEvent.modifierFlags.contains(.option)
        onDwell?(pos, optionHeld)
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}
