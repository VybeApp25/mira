import AppKit
import Foundation

// MARK: - Guidance evidence
//
// Instruments the Point-and-Ask loop so we can answer "does it actually work?"
// instead of guessing. Every detection writes an outcome event through the
// existing local-only TelemetryService; when an element is located we arm a
// one-shot global click watcher to capture an *implicit* correctness signal —
// did the user click near where Mira pointed, and how soon?
//
// Implicit-first by design (zero friction). An explicit "did that help?" eval
// mode can layer on later for the formal 20-task accuracy gate; the funnel
// shape below already leaves room for it.

@MainActor
final class GuidanceEvidenceService {

    static let shared = GuidanceEvidenceService()
    private init() {}

    // A click within this radius of the pointed location, within this window,
    // counts as the user acting on Mira's guidance. Points (not pixels): the
    // located target and NSEvent.mouseLocation are both global AppKit points.
    private let actRadiusPt:  CGFloat      = 64
    private let actWindowSec: TimeInterval = 8

    // At most one click watch armed at a time — a newer Point-and-Ask supersedes
    // an older pending one.
    private var clickMonitor: Any?
    private var watchTimer:   Timer?

    // MARK: - Recording

    /// Top of the funnel: a Point-and-Ask detection is about to run.
    func recordRequested(id: UUID, transcriptChars: Int) {
        TelemetryService.shared.track(.guidanceRequested(id: id, transcriptChars: transcriptChars))
    }

    /// Records the detection outcome. For `.located`, also arms the implicit
    /// acted-on watcher. `normalized` is only used for the located case (so the
    /// funnel can later inspect where on screen Mira tends to point).
    func recordOutcome(id: UUID, detection: GuidanceDetection, normalized: CGPoint?, display: String) {
        switch detection {
        case .located(let appKitPt):
            let n = normalized ?? .zero
            TelemetryService.shared.track(.guidanceLocated(id: id, nx: Double(n.x), ny: Double(n.y), display: display))
            armClickWatch(id: id, target: appKitPt)

        case .noElement:
            TelemetryService.shared.track(.guidanceNoElement(id: id))

        case .failed(let reason):
            TelemetryService.shared.track(.guidanceFailed(id: id, reason: reason))
        }
    }

    // MARK: - Implicit acted-on signal

    private func armClickWatch(id: UUID, target: CGPoint) {
        disarmClickWatch()                    // newest point wins
        let armedAt = Date()

        // Global mouse-down monitor — works without Accessibility for mouse events
        // (same approach as PointFollowUpService).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let click    = NSEvent.mouseLocation
                let dist     = hypot(click.x - target.x, click.y - target.y)
                let latency  = Date().timeIntervalSince(armedAt)
                if dist <= self.actRadiusPt {
                    TelemetryService.shared.track(
                        .guidanceActedOn(id: id, distancePt: Double(dist), afterSeconds: latency))
                }
                // First click ends the watch either way: a click elsewhere means
                // the user moved on, so we don't keep listening.
                self.disarmClickWatch()
            }
        }

        watchTimer = Timer.scheduledTimer(withTimeInterval: actWindowSec, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.disarmClickWatch() }
        }
    }

    private func disarmClickWatch() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        watchTimer?.invalidate(); watchTimer = nil
    }

    // MARK: - Funnel

    /// Reads the guidance funnel from telemetry. Funnel — not a composite score —
    /// per the Phase 15 rule: surface the stages first, judge later.
    func funnel(since: Date? = nil) -> GuidanceFunnel {
        let t = TelemetryService.shared
        return GuidanceFunnel(
            requested: t.count("guidance_requested", since: since),
            located:   t.count("guidance_located",   since: since),
            noElement: t.count("guidance_no_element", since: since),
            failed:    t.count("guidance_failed",     since: since),
            actedOn:   t.count("guidance_acted_on",   since: since)
        )
    }
}

// MARK: - Funnel model

/// One pass through Point-and-Ask, in stages:
///   requested → (located | noElement | failed) → actedOn
struct GuidanceFunnel {
    let requested: Int
    let located:   Int
    let noElement: Int
    let failed:    Int
    let actedOn:   Int

    /// Of requests that completed (located+noElement+failed), how often did we
    /// actually point at something. nil until there's data.
    var locateRate: Double? {
        let resolved = located + noElement + failed
        return resolved > 0 ? Double(located) / Double(resolved) : nil
    }

    /// Of the times we pointed, how often the user then clicked there — the
    /// implicit "the guidance was useful" proxy. This is the number the 20-task
    /// accuracy gate is really about.
    var actOnRate: Double? {
        located > 0 ? Double(actedOn) / Double(located) : nil
    }

    /// Of completed requests, how often detection outright failed (errors, not
    /// "nothing to point at"). A health signal, distinct from accuracy.
    var failureRate: Double? {
        let resolved = located + noElement + failed
        return resolved > 0 ? Double(failed) / Double(resolved) : nil
    }
}
