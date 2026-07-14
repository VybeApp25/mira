import Foundation

// MARK: - Teaching models (Teaching System M2)
//
// See docs/architecture/teaching_system.md §3. A lesson is an ordered list of
// steps; each step advances ONLY when its success check is satisfied by an
// observation (or an explicit user confirmation) — never optimistically.

/// What a step wants Mira to point at. The description is fed to the same
/// grounding path as Point-and-Ask (M1).
struct NamedTarget: Equatable {
    /// Natural-language description of the element ("the Appearance row in the sidebar").
    let description: String
}

/// How Mira establishes that a step is complete. The provenance of completion
/// matters: only `observed` and `userConfirmation` may advance a step.
enum SuccessCheck: Equatable {
    /// Observed: the given app became frontmost.
    case appFrontmost(bundleId: String)
    /// Observed: macOS is now in Dark Mode (read directly from the system).
    case darkModeEnabled
    /// Observed by VISION: a described visible outcome is now true on screen
    /// ("the Channel rack shows a new FLEX Bass channel"). Unlike the deterministic
    /// checks above, this is a model verdict, so it is second-class evidence:
    /// it advances a step only at/above a confidence threshold, is recorded with a
    /// distinct provenance (`.visionObserved`), and always keeps a userConfirmation
    /// fallback after the observe window. This is what lets Mira coach inside an
    /// arbitrary app (a DAW, an editor) instead of falling back to "tap Done".
    /// See docs/architecture/learn_along.md (LA-0).
    case visualState(prompt: String)
    /// Not observable by Mira → ask the user ("Done" / "Skip"). Recorded honestly.
    case userConfirmation
}

/// What Mira physically does at a step's grounded target when it performs the
/// step itself (autonomous mode). Default `.click`. The text in `.type` is the
/// *task's* text, authored into the lesson — never the user's private content: a
/// step that needs the user's own data stays a `.click` and Mira focuses the
/// field and hands back rather than fabricating it.
enum StepAction: Equatable {
    case click
    case doubleClick
    case type(text: String)
    case key(combo: String)   // e.g. "cmd+s", "return", "cmd+shift+4"

    /// Click / double-click need a grounded on-screen point. Typing and keyboard
    /// shortcuts act on whatever is focused, so they can run without a target —
    /// when a `.type` step DOES carry a target we still ground it to click-focus
    /// the right field first, but if grounding fails (e.g. a blank, featureless
    /// text area the vision model can't point at) we fall back to typing into the
    /// currently focused element rather than refusing to act.
    var needsTarget: Bool {
        switch self {
        case .click, .doubleClick: return true
        case .type, .key:          return false
        }
    }
}

/// One teaching step.
struct TeachingStep: Equatable, Identifiable {
    let id:           String
    let instruction:  String         // shown to the user
    let target:       NamedTarget?   // grounded + annotated; nil = no on-screen pointer
    let successCheck: SuccessCheck
    let remediation:  String         // shown after the observe window lapses
    /// Seconds to watch for the observed outcome before offering remediation/skip.
    let observeWindow: TimeInterval
    /// What Mira does at the target in autonomous mode. Defaults to `.click`.
    let action:       StepAction

    init(id: String, instruction: String, target: NamedTarget? = nil,
         successCheck: SuccessCheck, remediation: String = "Take your time — I'll keep watching.",
         observeWindow: TimeInterval = 30, action: StepAction = .click) {
        self.id = id; self.instruction = instruction; self.target = target
        self.successCheck = successCheck; self.remediation = remediation
        self.observeWindow = observeWindow; self.action = action
    }
}

/// A hardcoded mini-skill (M2). Becomes a loadable Skill bundle in M3.
struct TeachingSkill: Equatable, Identifiable {
    let id:    String          // stable skill id (telemetry key)
    let title: String
    let steps: [TeachingStep]
    /// Bundle id of the app this skill teaches in (from the manifest). Used to
    /// keep grounding honest: a target that resolves to a *different* app's UI
    /// (e.g. Mira's own overlay) is a mis-ground, not a confident hit.
    var domainApp: String? = nil
    /// Grounding tier from the manifest: "accessibility" | "vision". AX-grounded
    /// skills require an actionable AX element under the ring (so an empty-space
    /// mis-ground routes to ASK); vision skills trust the vision point as-is.
    var grounding: String? = nil
    /// LA-2: a source tutorial (e.g. a YouTube URL) opened alongside when the lesson
    /// runs, so the learner can watch and do at once.
    var tutorialURL: String? = nil
}

/// How a step's completion was established — drives honest mastery later (M4).
enum CompletionProvenance: String {
    case observation
    case userConfirmation
    /// A VISION verdict satisfied the step (`.visualState`). Recorded distinctly
    /// from `observation` (a deterministic system read) because a model saying "it
    /// looks done" is weaker evidence than reading the system state directly — M4
    /// mastery must never treat the two as equal.
    case visionObserved
    /// Mira performed the step itself in autonomous mode — recorded distinctly so
    /// it never masquerades as a human confirmation or an observed outcome.
    case autonomous
}
