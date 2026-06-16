import AppKit
import ApplicationServices

// MARK: - Element Grounding (Teaching System M1)
//
// Turns a *named* target ("the snap-to-grid toggle") into a *verified* on-screen
// location — or honestly reports that it can't. See docs/architecture/teaching_system.md §2.
//
// This is where the teaching honesty invariant ("claimed but unobserved →
// forbidden") becomes code: Mira never draws an annotation at a location it is
// not confident about. Low confidence routes to an ASK, not a guess.
//
// Tiers, best-available:
//   1. Accessibility (AX) — exact, cheap, reliable where the app exposes it.
//   2. Computer Use vision (ElementLocationDetector) — where AX is missing.
//   3. None — neither produced a confident location.

enum GroundingSource { case accessibility, vision }

/// Outcome of grounding one target.
enum GroundingOutcome {
    /// A location was grounded. `location` is normalized (0–1, top-left) for the
    /// canvas; `appKit` is the raw global point for evidence/click-tracking.
    /// `confidence` 0–1; `source` records how it was grounded.
    case grounded(location: CGPoint, appKit: CGPoint, source: GroundingSource, confidence: Double)
    /// The model is confident there is no specific element to point at — a valid
    /// teaching state (e.g. a conceptual question), not a failure.
    case noElement
    /// Grounding could not complete confidently → the caller must ASK, not draw.
    case uncertain(reason: String)
}

/// What the canvas/teaching layer should do with a grounding outcome.
enum GateDecision { case annotate, ask, nothingToShow }

/// Pure gate — no OS calls, no side effects (mirrors `evaluateCapabilityState`).
/// The single chokepoint that enforces "never draw on what you can't ground".
func gateDecision(for outcome: GroundingOutcome, threshold: Double = 0.5) -> GateDecision {
    switch outcome {
    case .grounded(_, _, _, let confidence): return confidence >= threshold ? .annotate : .ask
    case .noElement:                      return .nothingToShow
    case .uncertain:                      return .ask
    }
}

@MainActor
final class GroundingService {
    static let shared = GroundingService()
    private init() {}

    /// Grounds the element the user asked about. `displayFrame` is the captured
    /// display's NSScreen.frame (AppKit coords), matching ElementLocationDetector.
    /// `expectedBundleId` (optional) is the app the target should live in (the
    /// skill's `domainApp`). When set, a grounded point that resolves to a
    /// *different* app's UI — most often Mira's own overlay/notifications — is
    /// treated as a mis-ground and routed to ASK instead of drawn confidently.
    func ground(question: String, screenshotData: Data, displayFrame: CGRect,
                expectedBundleId: String? = nil, requireActionableAX: Bool = false) async -> GroundingOutcome {
        switch await ElementLocationDetector.shared.detectElementLocation(
            screenshotData: screenshotData,
            userQuestion:   question,
            displayFrame:   displayFrame
        ) {
        case .failed(let reason):
            return .uncertain(reason: reason)

        case .noElement:
            return .noElement

        case .located(let appKitPt):
            // Use the vision point as-is. AX adds a confidence signal but must NOT
            // move the point — snapping to AX element centers proved to scatter the
            // ring onto wrong/oversized elements. (Precision is a measured M1 gate,
            // not a one-sample guess. See docs/architecture/teaching_system.md.)
            let (source, confidence) = verify(appKitPt: appKitPt, expectedBundleId: expectedBundleId,
                                              requireActionableAX: requireActionableAX)
            let normalized = ElementLocationDetector.shared.normalizedPoint(appKitPt, displayFrame: displayFrame)
            return .grounded(location: normalized, appKit: appKitPt, source: source, confidence: confidence)
        }
    }

    // MARK: - AX verification (tier 1 over the vision coordinate)

    /// Cross-checks the vision coordinate against the accessibility tree. A hit on
    /// an actionable element is the strongest grounding signal; a hit on a generic
    /// element is moderate; AX seeing *nothing* where vision pointed lowers
    /// confidence below the gate so we ask instead of drawing on empty space.
    /// Degrades gracefully when Accessibility isn't granted (→ trust vision only).
    /// Returns the grounding source and a confidence. AX is used only to enrich
    /// confidence — it never moves the vision point.
    private func verify(appKitPt: CGPoint, expectedBundleId: String? = nil,
                        requireActionableAX: Bool = false) -> (GroundingSource, Double) {
        guard AXIsProcessTrusted() else {
            return (.vision, 0.60)   // can't verify; trust the vision tier moderately
        }

        // AppKit global (bottom-left origin) → CG/AX global (top-left origin).
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cgX = Float(appKitPt.x)
        let cgY = Float(primaryH - appKitPt.y)

        // AX is a confidence ENRICHER, not a blocker (its absence must never reject a
        // ground the vision model got right — that just over-ASKs on visible targets).
        // Use the SYSTEM-WIDE element: it's the only mode that reliably hit-tests by
        // position (an app-scoped element returns nothing). It returns the topmost
        // window's element, which may be one of Mira's own overlays — that's fine, we
        // just can't corroborate through it. Probe a small neighborhood (CU coords are a
        // few px imprecise). An actionable target-app element nearby UPGRADES to high
        // confidence; the exact point on a *different* app downgrades to a mis-ground;
        // everything else keeps the vision baseline so the ring still draws.
        let system = AXUIElementCreateSystemWide()
        let own = Bundle.main.bundleIdentifier
        let offsets: [(Float, Float)] = [(0, 0), (-11, 0), (11, 0), (0, -11), (0, 11),
                                         (-9, -9), (9, -9), (-9, 9), (9, 9)]
        var actionableHit = false
        var sawWrongApp = false

        // Mira's own full-screen click-through overlays (the always-on guided
        // cursor, the annotation canvas) sit above every app window, so an AX
        // hit-test at ANY point lands on *our* window first — we skip it as
        // own-app, but because the overlay is full-screen every offset resolves to
        // it and we can never reach the real target. Order those overlays out for
        // the synchronous duration of the probe and restore them immediately:
        // hide → probe → restore all run in one main-thread turn before the next
        // compositor frame, so the cursor never visibly flickers.
        withFullScreenOverlaysHidden {
            for (dx, dy) in offsets {
                var e: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, cgX + dx, cgY + dy, &e) == .success,
                      let e else { continue }
                let owner = owningBundleId(of: e)
                if owner == own { continue }                        // a Mira window still up — can't verify through it
                if let expected = expectedBundleId, owner != expected {
                    if dx == 0, dy == 0 { sawWrongApp = true }      // exact hit is a different app
                    continue
                }
                if isActionable(e) { actionableHit = true; break }
            }
        }

        if actionableHit { return (.accessibility, 0.92) }   // corroborated → high
        if sawWrongApp { return (.vision, 0.20) }             // clear wrong-app → ASK
        return (.vision, 0.60)                                // can't corroborate → ring still draws
    }

    /// Runs `body` with Mira's own full-screen click-through overlay windows
    /// ordered out, then restores them. See `verify()` for why this is needed.
    /// Synchronous on the main thread: the hide and restore bracket `body` within
    /// a single run-loop turn, so no frame is composited in between — the overlays
    /// disappear from the window server's position hit-test (which backs
    /// AXUIElementCopyElementAtPosition) without ever visibly blinking.
    private func withFullScreenOverlaysHidden(_ body: () -> Void) {
        let occluders = NSApp.windows.filter { win in
            win.isVisible && win.ignoresMouseEvents && isFullScreenSized(win)
        }
        occluders.forEach { $0.orderOut(nil) }
        defer { occluders.forEach { $0.orderFrontRegardless() } }
        body()
    }

    /// True when the window covers (essentially) an entire display — the shape of
    /// our overlays, and exactly what makes them occlude every AX hit-test. Small
    /// surfaces like the notch island or the agent HUD are left untouched.
    private func isFullScreenSized(_ win: NSWindow) -> Bool {
        NSScreen.screens.contains { s in
            let f = s.frame, w = win.frame
            return abs(w.width - f.width) < 2 && abs(w.height - f.height) < 2
                && abs(w.minX - f.minX) < 2 && abs(w.minY - f.minY) < 2
        }
    }

    /// Bundle id of the app that owns an AX element, via its pid.
    private func owningBundleId(of el: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Treat an element as actionable if it advertises any action (e.g. AXPress)
    /// or carries a known interactive role.
    private func isActionable(_ el: AXUIElement) -> Bool {
        var actions: CFArray?
        if AXUIElementCopyActionNames(el, &actions) == .success,
           let names = actions as? [String], !names.isEmpty {
            return true
        }

        var roleRef: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            return Self.interactiveRoles.contains(role)
        }
        return false
    }

    private static let interactiveRoles: Set<String> = [
        kAXButtonRole as String, "AXLink", kAXMenuItemRole as String,
        kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXTextFieldRole as String,
        kAXTextAreaRole as String, kAXPopUpButtonRole as String, kAXComboBoxRole as String,
        kAXSliderRole as String, kAXTabGroupRole as String, kAXDisclosureTriangleRole as String,
    ]
}
