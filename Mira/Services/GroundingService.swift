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

        // Probe the topmost NON-Mira app window at the point and hit-test WITHIN it,
        // rather than the system-wide top element. The screen capture excludes Mira's
        // windows, so the model grounds against the target app — but a system-wide AX
        // probe lands on our own full-screen click-through overlay/HUD that sits on top.
        // Scoping to the real app's AXUIElement makes the cross-check match what the
        // model saw, so the confidence tiers below actually engage.
        let probe = CGPoint(x: CGFloat(cgX), y: CGFloat(cgY))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var element: AXUIElement?
        if let pid = Self.topmostAppPID(at: probe, excludingPID: ownPID) {
            AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), cgX, cgY, &element)
        }
        guard let el = element else {
            // No real app window under the point (empty desktop) or AX couldn't read
            // it. For a vision-grounded skill that's expected (custom UI) → vision
            // baseline; for an AX-grounded skill a real target SHOULD expose an element
            // here, so silence is disconfirmation (likely an empty-space mis-ground) → ASK.
            return requireActionableAX ? (.vision, 0.35) : (.vision, 0.60)
        }

        // Our own full-screen click-through annotation overlay sits above everything,
        // so the AX probe can hit IT instead of the target app — flagging a perfectly
        // correct ground as a "wrong app" mis-ground. We can't AX-verify through our
        // own window, so fall back to the vision tier instead of disconfirming.
        // (The teaching engine also hides the overlay before grounding; belt-and-braces.)
        if owningBundleId(of: el) == Bundle.main.bundleIdentifier {
            return (.vision, 0.60)
        }

        // App-ownership check: if the skill names a target app, the grounded
        // element must belong to it. A hit on a different app's UI — Mira's own
        // overlay/notifications, or whatever happens to sit where vision pointed —
        // is a mis-ground. Drop below the gate so we ASK instead of confidently
        // ringing the wrong thing. (This is the honest fix for "console closed →
        // ring landed on a Mira notification card".)
        if let expected = expectedBundleId, let owner = owningBundleId(of: el), owner != expected {
            return (.vision, 0.20)
        }

        if isActionable(el) { return (.accessibility, 0.92) }

        // Right app, but a non-actionable element (a container/label/empty chrome).
        // For an AX-grounded skill the ring should sit on something actionable, so a
        // non-actionable hit is a weak/likely-off ground → ASK. For a vision skill,
        // keep the moderate vision-backed pass (its targets may not be actionable AX
        // nodes at all). Honesty bias: a false ASK ("find it yourself") costs less
        // than a confident ring on the wrong thing.
        return requireActionableAX ? (.vision, 0.40) : (.accessibility, 0.75)
    }

    /// PID of the frontmost on-screen window at `p` (top-left global coords) that
    /// is NOT owned by `excludingPID` (Mira). Lets the AX probe see PAST our own
    /// full-screen overlay/HUD to the real app underneath. Desktop wallpaper/icons
    /// are excluded, so a hit on empty desktop returns nil (→ honest "nothing here").
    static func topmostAppPID(at p: CGPoint, excludingPID: pid_t) -> pid_t? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        // CGWindowListCopyWindowInfo returns windows front-to-back.
        for w in infos {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { continue }
            if CGRect(x: x, y: y, width: width, height: height).contains(p) { return pid }
        }
        return nil
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
