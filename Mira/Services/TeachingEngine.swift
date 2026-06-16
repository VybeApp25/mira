import AppKit

// MARK: - Teaching Engine (Teaching System M2)
//
// Walks a skill's steps: present → ground+annotate (reusing M1) → observe →
// advance. The honesty invariant ("claimed but unobserved → forbidden") is
// enforced structurally here:
//   • An OBSERVABLE step can only be completed by SuccessObserver returning true.
//     The HUD shows no "Done" button for it — the user cannot self-certify it.
//   • A .userConfirmation step is the only kind the user can mark done, and it is
//     recorded with that provenance, never as an observation.
//   • A skipped step is recorded as FAILED, never completed.
// See docs/architecture/teaching_system.md §3.

@MainActor
final class TeachingEngine: ObservableObject {
    static let shared = TeachingEngine()
    private init() {}

    enum Phase: Equatable { case idle, running, finished }

    // Published state the HUD observes.
    @Published private(set) var skill:        TeachingSkill?
    @Published private(set) var stepIndex:    Int = 0
    @Published private(set) var instruction:  String = ""
    @Published private(set) var statusLine:   String = ""
    @Published private(set) var phase:        Phase = .idle
    /// True only on .userConfirmation steps — the user may mark these done.
    @Published private(set) var canConfirm:   Bool = false
    /// True once the observe window has lapsed — lets the user give up on a step.
    @Published private(set) var canSkip:      Bool = false
    /// Set when a synthetic (foreign-process) tap was seen on Mira's own HUD during
    /// a lesson — a near-certain sign automation is operating the screen. Mira
    /// can't police the target app's buttons, so the honest response is to refuse
    /// to advance (already enforced) and warn the user. A genuine click clears it.
    @Published private(set) var automatedInputDetected: Bool = false

    var totalSteps: Int { skill?.steps.count ?? 0 }

    private var runTask: Task<Void, Never>?

    // A user action (Done/Skip) is honored ONLY for the exact step it was issued
    // against. Each step gets a unique generation; a tap records the generation
    // that was on screen when tapped, and `observe` accepts only a tap whose
    // generation matches the current step. A stale tap — left over from a prior
    // step or a prior lesson — can never satisfy a later step. This closes the
    // `confirmRequested` leak that let .userConfirmation steps auto-complete with
    // no real confirmation (verified live on Xcode 2026-06-14).
    private var stepGeneration      = 0
    private var confirmedGeneration: Int? = nil
    private var skippedGeneration:   Int? = nil

    // MARK: - Control

    /// Starts (or resumes) a skill. `fromStepIndex` lets the learner model resume
    /// after the last completed step from a prior session.
    func start(_ skill: TeachingSkill, fromStepIndex: Int = 0) {
        stop()
        self.skill = skill
        phase = .running
        // Collapse the island so the expanded Lessons list doesn't sit over the
        // target app and overlap the on-screen ring. The bottom HUD guides the
        // lesson from here; the screen-top stays clear for the real app.
        NotificationCenter.default.post(name: .miraRequestCollapse, object: nil)
        TelemetryService.shared.track(.lessonStarted(skillId: skill.id, totalSteps: skill.steps.count))
        let startAt = max(0, min(fromStepIndex, skill.steps.count - 1))
        runTask = Task { await run(skill, from: startAt) }
    }

    /// User tapped "Done" — honored only while a .userConfirmation step is shown
    /// (`canConfirm`), recorded against that step's generation so it can never
    /// carry forward to a later step, AND only when the tap is a genuine human
    /// action. A click synthesized and posted by another process (an autoclicker
    /// or UI-automation harness) is refused — otherwise `userConfirmation` would
    /// "complete" with no real user, breaking claimed-but-unobserved → forbidden.
    func confirmStep() {
        guard canConfirm else { return }
        guard isGenuineUserAction() else { rejectSyntheticTap(); return }
        confirmedGeneration = stepGeneration
    }
    func skipStep() {
        guard canSkip else { return }
        guard isGenuineUserAction() else { rejectSyntheticTap(); return }
        skippedGeneration = stepGeneration
    }

    /// Whether the event currently being dispatched is a real human input rather
    /// than one synthesized and posted by another process. A genuine click is
    /// delivered by the WindowServer with event-source PID 0; a posted click
    /// carries the posting process's PID. Conservative by design: when the source
    /// can't be read, or the PID is 0 / our own, the tap is HONORED — so a real
    /// user click is never wrongly refused. Only a clear foreign poster is denied.
    private func isGenuineUserAction() -> Bool {
        guard let cg = NSApp.currentEvent?.cgEvent else { return true }
        let pid = cg.getIntegerValueField(.eventSourceUnixProcessID)
        if pid == 0 { return true }
        if pid == Int64(ProcessInfo.processInfo.processIdentifier) { return true }
        return false
    }

    private func rejectSyntheticTap() {
        let stepId = skill.flatMap { stepIndex < $0.steps.count ? $0.steps[stepIndex].id : nil } ?? ""
        NSLog("[Teaching] Ignored a synthetic tap (posted by another process) on step \"%@\" — userConfirmation requires a genuine action.", stepId)
        if let skillId = skill?.id {
            TelemetryService.shared.track(.stepConfirmRejected(
                skillId: skillId, stepId: stepId, reason: "synthetic_input"))
        }
        // Surface the condition: automation is operating the screen. Pull the ring
        // so Mira stops pointing at a real control an autoclicker could hit, and
        // warn. Mira can't stop another process — but it won't participate or
        // pretend a step completed. A genuine click later clears this.
        automatedInputDetected = true
        AnnotationCanvasService.shared.clear()
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        AnnotationCanvasService.shared.clear()
        TeachingHUD.shared.hide()
        phase = .idle
        skill = nil
        canConfirm = false; canSkip = false
        instruction = ""; statusLine = ""
        confirmedGeneration = nil; skippedGeneration = nil
        automatedInputDetected = false
    }

    // MARK: - Run loop

    private func run(_ skill: TeachingSkill, from startIndex: Int) async {
        // Steps before the resume point were completed in a prior session.
        var completed = startIndex
        TeachingHUD.shared.show()

        for i in startIndex..<skill.steps.count {
            let step = skill.steps[i]
            if Task.isCancelled { break }
            stepIndex = i
            instruction = step.instruction
            statusLine = ""
            // New generation for this step — any earlier Done/Skip tap is now stale.
            stepGeneration += 1
            confirmedGeneration = nil; skippedGeneration = nil
            automatedInputDetected = false   // fresh step — a prior synthetic-tap warning is cleared
            // Only user-confirmation steps may be self-certified.
            canConfirm = (step.successCheck == .userConfirmation)
            canSkip = false
            TelemetryService.shared.track(.stepInstructed(skillId: skill.id, stepId: step.id))

            let groundedPoint = await groundAndAnnotate(step, number: i + 1)

            // Autonomous mode: Mira performs the grounded step itself (a real click)
            // instead of guiding. Only confident grounds, only user-confirmation steps,
            // and risky/irreversible steps fall back to manual when "Confirm risky" is on.
            if autonomousEnabled, step.successCheck == .userConfirmation, let n = groundedPoint {
                var outcome = await autoPerform(step: step, at: n)
                if outcome == .noEffect {
                    // Self-correct: the click likely missed → re-ground once and retry.
                    TelemetryService.shared.track(.stepOutcome(skillId: skill.id, stepId: step.id, result: "retried"))
                    if let n2 = await groundAndAnnotate(step, number: i + 1) {
                        outcome = await autoPerform(step: step, at: n2)
                    }
                }
                if outcome == .performed {
                    TelemetryService.shared.track(.stepOutcome(skillId: skill.id, stepId: step.id, result: "verified"))
                    TelemetryService.shared.track(.stepCompleted(
                        skillId: skill.id, stepId: step.id, groundedBy: CompletionProvenance.autonomous.rawValue))
                    completed += 1
                    AnnotationCanvasService.shared.clear()
                    continue
                }
                if outcome == .noEffect {
                    // Tried twice, nothing changed → be honest and hand back to the user.
                    TelemetryService.shared.track(.stepOutcome(skillId: skill.id, stepId: step.id, result: "unverified"))
                    statusLine = "I clicked but nothing changed — do this one and I'll continue."
                }
                // .deferred or unverified → fall through to observe (manual).
            }

            let result = await observe(step, generation: stepGeneration)
            switch result {
            case .observed:
                TelemetryService.shared.track(.stepCompleted(
                    skillId: skill.id, stepId: step.id, groundedBy: CompletionProvenance.observation.rawValue))
                completed += 1
            case .confirmed:
                TelemetryService.shared.track(.stepCompleted(
                    skillId: skill.id, stepId: step.id, groundedBy: CompletionProvenance.userConfirmation.rawValue))
                completed += 1
            case .skipped:
                TelemetryService.shared.track(.stepFailed(skillId: skill.id, stepId: step.id, reason: "skipped"))
            case .cancelled:
                AnnotationCanvasService.shared.clear()
                return
            }
            AnnotationCanvasService.shared.clear()
        }

        TelemetryService.shared.track(.lessonCompleted(
            skillId: skill.id, completedSteps: completed, totalSteps: skill.steps.count))
        phase = .finished
        instruction = completed == skill.steps.count ? "Done — nicely done." : "Lesson ended."
        statusLine = "\(completed)/\(skill.steps.count) steps completed"
        canConfirm = false; canSkip = false
        // Leave the summary up briefly, then tear down.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if !Task.isCancelled { stop() }
    }

    private enum StepResult { case observed, confirmed, skipped, cancelled }

    private func observe(_ step: TeachingStep, generation: Int) async -> StepResult {
        // If the goal is already true when the step begins, it's honestly complete.
        if SuccessObserver.isSatisfied(step.successCheck) == true { return .observed }

        let deadline = Date().addingTimeInterval(step.observeWindow)
        var remediated = false

        while !Task.isCancelled {
            if SuccessObserver.isSatisfied(step.successCheck) == true { return .observed }

            // A confirm counts only if it was issued for THIS step's generation, and
            // only on a user-confirmation step — so an observable step can never be
            // falsely certified, and a stale tap can never carry forward.
            if step.successCheck == .userConfirmation, confirmedGeneration == generation {
                return .confirmed
            }
            if skippedGeneration == generation { return .skipped }

            if !remediated, Date() > deadline {
                remediated = true
                statusLine = step.remediation
                canSkip = true           // let the user move on after the window
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return .cancelled
    }

    // MARK: - Grounding + annotation (reuses M1)

    /// A concise label for the near-ring callout. The full instruction lives in the
    /// HUD; beside the target we want just the action — so we take the text up to
    /// the first em-dash/parenthetical aside, and cap the length.
    static func shortLabel(from instruction: String) -> String {
        var s = instruction
        for sep in [" — ", " – ", " (", ". "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 52 { s = String(s.prefix(50)).trimmingCharacters(in: .whitespaces) + "…" }
        return s.isEmpty ? instruction : s
    }

    /// One capture + ground pass for a target description. Throws only on capture
    /// failure; a "couldn't locate" result comes back as a non-grounded outcome.
    private func groundOnce(question: String) async throws -> GroundingOutcome {
        let screens = try await ScreenCaptureService.captureAllDisplaysAsJPEG()
        guard let primary = screens.first(where: { $0.isCursorScreen }) ?? screens.first else {
            return .uncertain(reason: "no_display")
        }
        return await GroundingService.shared.ground(
            question: question,
            screenshotData: primary.imageData,
            displayFrame: primary.displayFrame,
            expectedBundleId: skill?.domainApp,
            requireActionableAX: skill?.grounding == "accessibility")
    }

    /// Returns the grounded normalized point on the confident path (so autonomous
    /// mode can click it), or nil when there's no target or we couldn't ground.
    @discardableResult
    private func groundAndAnnotate(_ step: TeachingStep, number: Int) async -> CGPoint? {
        guard let target = step.target else {
            AnnotationCanvasService.shared.clear()
            return nil
        }
        // Hide any prior step's overlay BEFORE we capture + AX-probe, so the grounding
        // cross-check sees the real target app — not our own full-screen click-through
        // annotation window, which the AX probe would otherwise hit first and (wrongly)
        // flag a correct ground as a wrong-app mis-ground → ASK.
        AnnotationCanvasService.shared.clear()
        do {
            // Vision grounding is non-deterministic — it sometimes returns no coordinate
            // on a target that's plainly there. Try once; if it doesn't confidently
            // ground, take a second look before falling back to ASK.
            var outcome = try await groundOnce(question: target.description)
            if gateDecision(for: outcome) != .annotate,
               let retry = try? await groundOnce(question: target.description),
               gateDecision(for: retry) == .annotate {
                outcome = retry
            }

            switch (outcome, gateDecision(for: outcome)) {
            case (.grounded(let normalized, _, let source, let confidence), .annotate):
                AnnotationCanvasService.shared.show([
                    .ring(around: normalized, radiusPt: 26),
                    .badge(at: normalized, number: number),
                    .callout(near: normalized, text: Self.shortLabel(from: step.instruction))
                ])
                recordGrounding(step, grounded: true,
                                source: String(describing: source), confidence: confidence)
                await guideCursorIfEnabled(to: normalized, step: step)
                return normalized
            default:
                // Couldn't ground confidently — be honest, don't draw a guess.
                AnnotationCanvasService.shared.clear()
                statusLine = "I can't spot that on screen — find it yourself and continue."
                // Record the miss too: a silent mis-ground would be wrong-but-invisible.
                recordGrounding(step, grounded: false,
                                source: groundingSource(of: outcome), confidence: groundingConfidence(of: outcome))
                return nil
            }
        } catch {
            AnnotationCanvasService.shared.clear()
            recordGrounding(step, grounded: false, source: "error", confidence: 0)
            return nil
        }
    }

    // MARK: - Autonomous mode (opt-in: Settings → Autonomy)

    private var autonomousEnabled: Bool { UserDefaults.standard.bool(forKey: "mira_autonomous_enabled") }
    /// Defaults to TRUE when unset so a fresh enable of autonomous mode is cautious.
    private var confirmRiskyAutonomous: Bool {
        UserDefaults.standard.object(forKey: "mira_autonomous_confirm_risky") as? Bool ?? true
    }

    private static let riskyWords = [
        "send", "delete", "remove", "trash", "discard", "buy", "purchase", "pay",
        "order", "checkout", "submit", "publish", "post ", "overwrite", "replace",
        "sign out", "log out", "unsubscribe", "empty",
    ]
    /// Heuristic: does this step look irreversible/destructive? Keyed off the
    /// instruction + target text. Conservative — when "Confirm risky" is on, a hit
    /// here means Mira will NOT auto-click; the human does it.
    static func isRisky(_ step: TeachingStep) -> Bool {
        let t = (step.instruction + " " + (step.target?.description ?? "")).lowercased()
        return riskyWords.contains { t.contains($0) }
    }

    private static let contentWords = [
        "type", "write", "enter ", "fill in", "give it a title", "give the event a title",
        "name the", "compose", "search for", "paste",
    ]
    /// Does this step require the user's own text (an address, a title, a message)?
    /// Autonomous mode focuses the field but hands back rather than fabricating it.
    static func isContentEntry(_ step: TeachingStep) -> Bool {
        let t = step.instruction.lowercased()
        return contentWords.contains { t.contains($0) }
    }

    /// Outcome of one autonomous step attempt.
    enum AutoOutcome { case performed, noEffect, deferred }

    /// Autonomous mode: Mira performs the grounded step itself (a real click), then
    /// VERIFIES the screen actually changed before crediting it. `.deferred` = handed
    /// back to the human (risky / content-entry / automation detected). `.noEffect` =
    /// clicked but nothing moved (likely a missed ground) → the run loop re-grounds and
    /// retries. Completion is journaled with the distinct `.autonomous` provenance.
    private func autoPerform(step: TeachingStep, at normalized: CGPoint) async -> AutoOutcome {
        if Self.isRisky(step), confirmRiskyAutonomous {
            statusLine = "Paused — this looks irreversible. Do this one yourself, then it continues."
            canSkip = true
            return .deferred
        }
        guard !automatedInputDetected else { return .deferred }
        let cu = ComputerUseService.shared
        let x = Int(normalized.x * CGFloat(cu.displayWidth))
        let y = Int(normalized.y * CGFloat(cu.displayHeight))
        if Self.isContentEntry(step) {
            // The text here is the user's own content (an address, a title) — autonomous
            // mode must not fabricate it. Click to focus the field, then hand back.
            cu.click(x: x, y: y)
            statusLine = "Mira focused this field — type your text, then tap Done."
            canSkip = true
            return .deferred
        }
        // Let the ring/callout register so the user sees what's about to be clicked.
        statusLine = "Autonomous — Mira is doing this step…"
        try? await Task.sleep(nanoseconds: 900_000_000)
        if Task.isCancelled { return .deferred }
        // Outcome verification: fingerprint the screen, click, confirm it changed.
        let before = await cu.screenFingerprint()
        cu.click(x: x, y: y)
        try? await Task.sleep(nanoseconds: 800_000_000)   // let the target app react
        let after = await cu.screenFingerprint()
        if let b = before, let a = after {
            return cu.changedFraction(a, b) >= 0.02 ? .performed : .noEffect
        }
        return .performed   // couldn't fingerprint — don't get stuck, credit the action
    }

    /// Opt-in (Settings → Screen & Guidance → "Guide my cursor"). On a *confident*
    /// grounding, gently glides the real pointer to the target so it's already there
    /// when the user reaches for it. Mira NEVER clicks — the human still performs the
    /// action and Mira observes the result, so the "claimed but unobserved → forbidden"
    /// invariant holds. Skipped when automation is detected (don't chase a hijacked
    /// cursor) and only ever on the confident annotate path (never a guess).
    private func guideCursorIfEnabled(to normalized: CGPoint, step: TeachingStep) async {
        guard UserDefaults.standard.bool(forKey: "mira_guide_cursor") else { return }
        guard !automatedInputDetected else { return }
        let cu = ComputerUseService.shared
        let x  = Int(normalized.x * CGFloat(cu.displayWidth))
        let y  = Int(normalized.y * CGFloat(cu.displayHeight))
        await cu.glideMouse(toX: x, toY: y)
        if let skillId = skill?.id {
            TelemetryService.shared.track(.stepCursorGuided(skillId: skillId, stepId: step.id))
        }
    }

    /// Journals whether a ringed step's target actually grounded. The honest
    /// signal behind the "Unverified" badge and the instructed→attempted funnel.
    private func recordGrounding(_ step: TeachingStep, grounded: Bool, source: String, confidence: Double) {
        guard let skillId = skill?.id else { return }
        TelemetryService.shared.track(.stepGrounded(
            skillId: skillId, stepId: step.id, grounded: grounded, source: source, confidence: confidence))
    }

    private func groundingSource(of outcome: GroundingOutcome) -> String {
        if case .grounded(_, _, let source, _) = outcome { return String(describing: source) }
        return "none"
    }

    private func groundingConfidence(of outcome: GroundingOutcome) -> Double {
        if case .grounded(_, _, _, let confidence) = outcome { return confidence }
        return 0
    }
}
