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
        // LA-2: a lesson authored from a tutorial opens it alongside, so the learner
        // can watch and do at once. Best-effort — never blocks the lesson.
        if let t = skill.tutorialURL, let url = URL(string: t) {
            BrowserService.shared.open(url)
        }
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
            // Only user-confirmation steps may be self-certified up front. A
            // vision-observed step starts as "Mira is watching" (canConfirm false)
            // and only gains a Done fallback once its observe window lapses; but if
            // the feature is OFF it degrades to a plain user-confirmation step.
            canConfirm = (step.successCheck == .userConfirmation)
                || (isVisualStateCase(step) && !learnAlongEnabled)
            canSkip = false
            TelemetryService.shared.track(.stepInstructed(skillId: skill.id, stepId: step.id))

            let groundedPoint = await groundAndAnnotate(step, number: i + 1)

            // Hybrid execution: in autonomous mode, satisfy an "open app X" step via the
            // NSWorkspace API (launch + activate) rather than waiting for a UI action —
            // use a real API where one exists, UI clicking only where it doesn't.
            if autonomousEnabled, case .appFrontmost(let bundleId) = step.successCheck {
                await launchApp(bundleId)
            }

            // Autonomous mode: Mira performs the step itself (click, double-click,
            // type, or keyboard shortcut) instead of guiding. Only user-confirmation
            // steps; pointer actions need a confident ground (a keyboard shortcut
            // doesn't); risky/irreversible steps fall back to manual when "Confirm
            // risky" is on.
            if autonomousEnabled, step.successCheck == .userConfirmation,
               groundedPoint != nil || !step.action.needsTarget {
                var outcome = await autoPerform(step: step, at: groundedPoint)
                if outcome == .noEffect {
                    // Self-correct: the action likely missed → re-ground once and retry.
                    TelemetryService.shared.track(.stepOutcome(skillId: skill.id, stepId: step.id, result: "retried"))
                    let n2 = await groundAndAnnotate(step, number: i + 1)
                    if n2 != nil || !step.action.needsTarget {
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
            case .visionObserved:
                TelemetryService.shared.track(.stepCompleted(
                    skillId: skill.id, stepId: step.id, groundedBy: CompletionProvenance.visionObserved.rawValue))
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

    private enum StepResult { case observed, visionObserved, confirmed, skipped, cancelled }

    private func observe(_ step: TeachingStep, generation: Int) async -> StepResult {
        // If the goal is already true when the step begins, it's honestly complete.
        if SuccessObserver.isSatisfied(step.successCheck) == true { return .observed }

        let deadline = Date().addingTimeInterval(step.observeWindow)
        var remediated = false
        // Space vision checks out (they cost a model call). First check fires one
        // cadence in, giving the learner a beat to act before Mira looks.
        var lastVisionAt = Date()
        let visionStep = isVisionObserved(step)
        if visionStep { statusLine = "Watching your screen…" }

        while !Task.isCancelled {
            // Deterministic checks (appFrontmost / darkMode) — cheap, every tick.
            if SuccessObserver.isSatisfied(step.successCheck) == true { return .observed }

            // A confirm counts only if it was issued for THIS step's generation. The
            // `confirmStep()` guard (`canConfirm`) is the real gate — so an observable
            // step, whose canConfirm is never set, can never be falsely certified,
            // and a stale tap can never carry forward.
            if confirmedGeneration == generation { return .confirmed }
            if skippedGeneration == generation { return .skipped }

            // Vision-observed step: verify on a throttled cadence. A confident-enough
            // "yes" advances as `.visionObserved` (recorded distinctly). A "no", a
            // low-confidence "yes", or a failed call all keep watching — never a
            // false pass. The user's Done fallback (below) always remains.
            if visionStep, Date().timeIntervalSince(lastVisionAt) >= visionCadence,
               let prompt = visualStatePrompt(step) {
                lastVisionAt = Date()
                if let verdict = await runVisionCheck(prompt: prompt),
                   verdict.satisfied, verdict.confidence >= visionAdvanceThreshold {
                    TelemetryService.shared.track(.stepOutcome(
                        skillId: skill?.id ?? "", stepId: step.id, result: "vision_verified"))
                    return .visionObserved
                }
                if Task.isCancelled { break }
            }

            if !remediated, Date() > deadline {
                remediated = true
                statusLine = step.remediation
                canSkip = true           // let the user move on after the window
                // A vision-observed step now also gains a Done fallback: if Mira's
                // eyes keep missing it, the learner can assert completion themselves
                // (recorded honestly as userConfirmation, not as an observation).
                if visionStep { canConfirm = true }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return .cancelled
    }

    /// One throttled vision verification for a `.visualState` step. Captures the
    /// cursor display and asks whether the described outcome is now visibly true.
    private func runVisionCheck(prompt: String) async -> VisionStateVerifier.Verdict? {
        guard let screens = try? await ScreenCaptureService.captureAllDisplaysAsJPEG(),
              let primary = screens.first(where: { $0.isCursorScreen }) ?? screens.first else {
            return nil
        }
        return await VisionStateVerifier.shared.verify(
            description: prompt, screenshotData: primary.imageData)
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
    /// Confidence of the most recent `groundAndAnnotate` (0 when it didn't ground).
    /// Lets `autoPerform` trust an AX-corroborated click without the screen-diff check.
    private var lastGroundConfidence: Double = 0

    @discardableResult
    private func groundAndAnnotate(_ step: TeachingStep, number: Int) async -> CGPoint? {
        lastGroundConfidence = 0
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
                lastGroundConfidence = confidence
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

    // MARK: - Learn-Along (LA-0) — vision-verified steps
    //
    // When enabled, a `.visualState` step is OBSERVED by vision on a throttled
    // cadence; a confident-enough verdict advances it (recorded distinctly as
    // `.visionObserved`). When disabled, a `.visualState` step degrades safely to a
    // user-confirmed step. Either way the user always has a Done fallback once the
    // observe window lapses — a model that keeps saying "not yet" can never trap the
    // learner. See docs/architecture/learn_along.md.
    /// Defaults to TRUE when unset; only affects lessons that actually declare a
    /// `.visualState` step (none ship yet), so enabling it is inert until used.
    private var learnAlongEnabled: Bool {
        UserDefaults.standard.object(forKey: "mira_learn_along_enabled") as? Bool ?? true
    }
    /// Advance only when the model is at least this confident. Higher than the
    /// grounding gate (0.5): advancing a step is a stronger claim than pointing.
    private let visionAdvanceThreshold = 0.70
    /// Minimum seconds between vision checks while observing — bounds cost.
    private let visionCadence: TimeInterval = 2.5

    /// Whether this step is vision-observed AND the feature is on. When the feature
    /// is off, a `.visualState` step is treated as `.userConfirmation`.
    private func isVisionObserved(_ step: TeachingStep) -> Bool {
        isVisualStateCase(step) && learnAlongEnabled
    }
    private func isVisualStateCase(_ step: TeachingStep) -> Bool {
        if case .visualState = step.successCheck { return true }
        return false
    }
    /// The description a `.visualState` step wants verified, else nil.
    private func visualStatePrompt(_ step: TeachingStep) -> String? {
        if case .visualState(let p) = step.successCheck { return p }
        return nil
    }

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

    /// Hybrid execution: open + activate an app by bundle id via the NSWorkspace API,
    /// so an autonomous "open app X" step is satisfied directly instead of by clicking
    /// the Dock. Observation (`appFrontmost`) still confirms it actually came forward.
    private func launchApp(_ bundleId: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        statusLine = "Autonomous — opening the app…"
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    /// Outcome of one autonomous step attempt.
    enum AutoOutcome { case performed, noEffect, deferred }

    /// Autonomous mode: Mira performs the step itself — click, double-click, type
    /// the lesson's text, or send a keyboard shortcut — then VERIFIES the screen
    /// actually changed before crediting it. `.deferred` = handed back to the human
    /// (risky / user's-own-content / automation detected). `.noEffect` = acted but
    /// nothing moved (likely a missed ground) → the run loop re-grounds and retries.
    /// Completion is journaled with the distinct `.autonomous` provenance.
    private func autoPerform(step: TeachingStep, at normalized: CGPoint?) async -> AutoOutcome {
        if Self.isRisky(step), confirmRiskyAutonomous {
            statusLine = "Paused — this looks irreversible. Do this one yourself, then it continues."
            canSkip = true
            return .deferred
        }
        guard !automatedInputDetected else { return .deferred }
        let cu = ComputerUseService.shared

        // Resolve the on-screen point for actions that act on a target.
        var point: (x: Int, y: Int)? = nil
        if let n = normalized {
            point = (Int(n.x * CGFloat(cu.displayWidth)), Int(n.y * CGFloat(cu.displayHeight)))
        }
        if step.action.needsTarget, point == nil { return .deferred }

        // A plain *click* into a field that wants the user's own content (and whose
        // text wasn't authored into the lesson) must not be fabricated: focus it and
        // hand back. An explicit `.type` action carries the task's text, so it skips
        // this guard and is performed.
        if case .click = step.action, Self.isContentEntry(step), let p = point {
            cu.click(x: p.x, y: p.y)
            statusLine = "Mira focused this field — type your text, then tap Done."
            canSkip = true
            return .deferred
        }

        // Let the ring/callout register so the user sees what's about to happen.
        statusLine = Self.autoStatus(for: step.action)

        // A targetless type/shortcut acts on whoever holds keyboard focus. Frontmost
        // (observed) is NOT the same as key focus — so without this, keystrokes can
        // leak into whatever was focused before (a terminal, Mira's HUD, etc.). Bring
        // the lesson's app to the foreground first. Click-based actions don't need
        // this: the click itself focuses the right app.
        if point == nil { await focusDomainAppIfNeeded(for: step.action) }

        try? await Task.sleep(nanoseconds: 900_000_000)
        if Task.isCancelled { return .deferred }

        // An AX-corroborated ground (high confidence) means the action landed on a
        // real, actionable element — trust it. The whole-screen change check below is
        // blind to small/low-contrast effects (a popover opening, a toggle flipping),
        // so requiring it here wrongly scores a successful click as a miss. Keep the
        // fingerprint as the safety net only for lower-confidence vision clicks, where
        // a miss is genuinely plausible.
        if point != nil, lastGroundConfidence >= 0.9 {
            await perform(step.action, at: point, cu: cu)
            return .performed
        }

        // Outcome verification: fingerprint the screen, act, confirm it changed.
        let before = await cu.screenFingerprint()
        await perform(step.action, at: point, cu: cu)
        try? await Task.sleep(nanoseconds: 800_000_000)   // let the target app react
        let after = await cu.screenFingerprint()
        if let b = before, let a = after {
            return cu.changedFraction(a, b) >= 0.02 ? .performed : .noEffect
        }
        return .performed   // couldn't fingerprint — don't get stuck, credit the action
    }

    /// Brings the lesson's app (`skill.domainApp`) to the foreground so a targetless
    /// type/shortcut lands there, not in whatever else held keyboard focus. No-op for
    /// click/double-click (the click focuses the app) or when the skill has no domain
    /// app. Waits briefly so focus settles before keystrokes are posted.
    private func focusDomainAppIfNeeded(for action: StepAction) async {
        switch action {
        case .type, .key: break
        default:          return
        }
        guard let bundleId = skill?.domainApp,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        else { return }
        app.activate()
        try? await Task.sleep(nanoseconds: 350_000_000)   // let key focus settle
    }

    /// Executes one autonomous action. Typing first clicks to focus the field, then
    /// (after a beat so focus lands) types the task's text. A keyboard shortcut acts
    /// on whatever is already focused, so it ignores the point.
    private func perform(_ action: StepAction, at point: (x: Int, y: Int)?, cu: ComputerUseService) async {
        switch action {
        case .click:
            if let p = point { cu.click(x: p.x, y: p.y) }
        case .doubleClick:
            if let p = point { cu.doubleClick(x: p.x, y: p.y) }
        case .type(let text):
            if let p = point {
                cu.click(x: p.x, y: p.y)                          // focus the field
                try? await Task.sleep(nanoseconds: 250_000_000)  // let focus land
            }
            cu.type(text: text)
        case .key(let combo):
            cu.key(combination: combo)
        }
    }

    /// The status line shown just before an autonomous action, so the user can see
    /// what Mira is about to do.
    private static func autoStatus(for action: StepAction) -> String {
        switch action {
        case .click, .doubleClick: return "Autonomous — Mira is doing this step…"
        case .type:                return "Autonomous — Mira is typing the text…"
        case .key:                 return "Autonomous — Mira is using a keyboard shortcut…"
        }
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
