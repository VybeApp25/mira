import Foundation
import AppKit
import ApplicationServices

// MARK: - Actuation router
//
// The single entry point for "make this app do X." It decides HOW per app/action
// and hides the mechanism from callers (orchestrator, agents, intents). Tiers,
// best → last resort:
//
//   1. AX background   — AXActuationService press/setText. No cursor, no focus
//                        change. The default for AX-capable native apps.
//   2. AX-located cursor — when AX can't actuate (read-only field, no AXPress)
//                        but still exposes element *geometry*: bring the app
//                        forward, CGEvent-click/type the element's screen rect.
//                        Deterministic, no vision. Costs a focus change (the
//                        single-cursor tradeoff Tre accepted for full coverage).
//   3. Vision cursor    — AX exposes no geometry at all (canvas/games/some
//                        Electron). Hand off to ComputerUseOrchestrator (Claude
//                        vision). Surfaced here as .needsVision; wired in #4.
//
// See project_mira_autonomy_direction. Pairs with TaskAnnouncer so every routed
// task notifies + speaks on completion.

@MainActor
final class ActuationRouter {
    static let shared = ActuationRouter()
    private init() {}

    enum Action {
        case press(button: String)
        case setText(String, field: String?)

        /// Human phrasing for notifications/voice ("press the Send button").
        var phrasing: String {
            switch self {
            case .press(let b):          return "press the \(b) button"
            case .setText(_, let f):     return "fill in \(f.map { "the \($0) field" } ?? "the text field")"
            }
        }
    }

    enum Path: String {
        case axBackground = "AX background"
        case axCursor     = "AX-located cursor"
        case needsVision  = "vision cursor (handoff)"
    }

    struct Outcome {
        let path: Path
        let success: Bool
        let detail: String
        var summary: String { "[\(path.rawValue)] \(success ? "ok" : "FAILED") — \(detail)" }
    }

    // MARK: - Public entry

    /// Route and execute `action` on `bundleID`, returning how it went.
    func perform(_ action: Action, on bundleID: String) -> Outcome {
        let cap = AXActuationService.shared.inspectCapability(forBundleID: bundleID)
        guard cap.isRunning else {
            return Outcome(path: .axBackground, success: false, detail: "\(bundleID) is not running")
        }

        // Tier 1: AX background. If it throws a "cursor-fallback" signal we drop
        // to tier 2; a hard error (not trusted, set failed) is returned as-is.
        do {
            try actuateViaAX(action, on: bundleID)
            return Outcome(path: .axBackground, success: true, detail: action.phrasing)
        } catch let e as AXActuationService.ActuationError where e.isCursorFallbackSignal {
            return actuateViaCursor(action, on: bundleID, axReason: "\(e)")
        } catch {
            return Outcome(path: .axBackground, success: false, detail: "\(error)")
        }
    }

    // MARK: - Tier 1: AX background

    private func actuateViaAX(_ action: Action, on bundleID: String) throws {
        let ax = AXActuationService.shared
        switch action {
        case .press(let button):
            try ax.pressButton(titled: button, inBundleID: bundleID)
        case .setText(let value, let field):
            let wrote = try ax.setTextValue(value, titled: field, inBundleID: bundleID)
            // A silent no-op write (read-back empty when we wrote non-empty) is a
            // fallback signal, not success — push to the cursor tier.
            if wrote.isEmpty && !value.isEmpty {
                throw AXActuationService.ActuationError.notSettable(field.map { "\"\($0)\"" } ?? "(any)")
            }
        }
    }

    // MARK: - Tier 2: AX-located cursor (and tier-3 handoff)

    private func actuateViaCursor(_ action: Action, on bundleID: String, axReason: String) -> Outcome {
        let cua = ComputerUseService.shared
        // The label we need to locate on screen.
        let label: String
        switch action {
        case .press(let b):        label = b
        case .setText(_, let f):
            guard let f else {
                // No field name → can't locate geometry deterministically.
                return Outcome(path: .needsVision, success: false,
                               detail: "AX couldn't write (\(axReason)) and no field label to locate for cursor")
            }
            label = f
        }

        // Locate the element's screen rect via AX geometry.
        let frame: CGRect
        do {
            frame = try AXActuationService.shared.screenFrame(ofLabeled: label, inBundleID: bundleID)
        } catch {
            // No geometry exposed → genuine vision case (canvas/games). Handoff.
            return Outcome(path: .needsVision, success: false,
                           detail: "no AX geometry for \"\(label)\" — needs vision orchestrator")
        }

        // Cursor path requires the target be frontmost (single cursor / single
        // hit-test). Bring it forward, then click its center.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.activate()
        let cx = Int(frame.midX), cy = Int(frame.midY)
        cua.click(x: cx, y: cy)

        switch action {
        case .press:
            return Outcome(path: .axCursor, success: true,
                           detail: "clicked \"\(label)\" at (\(cx),\(cy)) after AX fallback (\(axReason))")
        case .setText(let value, _):
            // Click focused the field; type the value via CGEvent.
            cua.type(text: value)
            return Outcome(path: .axCursor, success: true,
                           detail: "typed into \"\(label)\" at (\(cx),\(cy)) after AX fallback (\(axReason))")
        }
    }
}
