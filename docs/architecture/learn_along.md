# Learn-Along — coach a user through a real app from a tutorial

**Status:** spec / proposed. Builds on the Teaching System (see `teaching_system.md`).

## 1. Goal

Close the one composed capability HeyClicky markets that Mira doesn't yet have:
*watch a tutorial → coach the user through doing it in the real app*, pointing at
the exact controls and **verifying real progress** — the "video, program, video,
program" loop, demoed coaching someone through FL Studio.

Mira already has every **primitive** for this. What's missing is the composition,
and it is blocked by exactly two limits in today's Teaching System:

1. **Grounding is single-point / UI-element oriented** — fine for a DAW's controls
   (the marketed case), so *not* a v1 blocker.
2. **`SuccessCheck` has only three cases** (`appFrontmost`, `darkModeEnabled`,
   `userConfirmation`) — so coaching inside an arbitrary app can never *observe*
   domain progress ("a loop was added"); every real step falls back to "tap Done."
   **This is the keystone gap.**

## 2. What already exists (reuse, don't rebuild)

| Piece | File | Role in learn-along |
|---|---|---|
| Teaching engine (present→ground→observe→advance, honesty invariant) | `Mira/Services/TeachingEngine.swift` | Runs the authored lesson unchanged |
| Success observer (polls real state) | `Mira/Services/SuccessObserver.swift` | Extend with an async vision check |
| Success/step models | `Mira/Models/TeachingModels.swift` | Add one `SuccessCheck` case |
| Lesson bundle format (SKILL.md + steps.json) | `Mira/Models/SkillBundle.swift`, `Mira/Services/SkillCatalog.swift` | Authoring target |
| Element grounding (vision + AX, confidence-gated) | `Mira/Services/GroundingService.swift` | Points at the control, already gated |
| Annotation canvas (ring/arrow/badge/callout) | `Mira/Services/AnnotationCanvasService.swift` | The on-screen marks (the "draw on your screen") |
| One-shot screen capture | `Mira/Services/ScreenCaptureService.swift` | Frame source for the vision check |
| Prompt→bundle authoring pattern | `ClaudeService.swift:401` (`createUserSkill`) | Copy the *pattern*, retarget to lessons |
| YouTube transcript | `youtube_transcript` python skill | Tutorial ingestion |
| Cost metering / quota | QuotaService / TaskRunLedger | Meter the vision checks |

Note the two-skill split: Create-a-Skill authors **prompt-skills** (`MiraSkillLoader`,
injected into the system prompt). Learn-along authors **teaching lessons**
(`SkillCatalog`, `steps.json`) — same authoring *shape*, different output.

## 3. Design — three workstreams

### WS1 · Vision-verified `SuccessCheck` (the keystone; unblocks any app)

Add one observable check that asks "is the desired visible outcome now true?"

- **Model** (`TeachingModels.swift`): add
  `case visualState(prompt: String)` to `SuccessCheck`. `prompt` is a concrete,
  checkable visible outcome authored into the lesson ("the Channel rack shows a
  new FLEX Bass channel").
- **DTO** (`SkillBundle.swift`): `SuccessCheckDTO.toDomain()` maps
  `type:"visualState"` + a `prompt` field → the new case. Unknown types still fail
  the load honestly (unchanged).
- **Observer** (`SuccessObserver.swift`): today `isSatisfied` is **synchronous** and
  the engine polls it every 400 ms (`TeachingEngine.swift:230`). A vision check is
  async and costs tokens, so:
  - Add `static func verifyAsync(_ check) async -> Bool?` that captures the frame
    (`ScreenCaptureService.captureMainDisplay`) and asks a cheap vision model a
    yes/no with confidence. Return `true` only at/above a confidence threshold
    (mirror `gateDecision`); otherwise `false`/`nil`.
  - **Split the poll cadence** in `observe()`: keep sync checks at 400 ms; run the
    vision check on a slower cadence (~2.5 s). *Shipped in LA-0.* A cheap frame-diff
    change-gate (skip the call when the screen hasn't changed) is a fast-follow cost
    optimization — deliberately left out of the first cut because a naive diff can
    skip a real change and stall a step; throttle-only never skips a needed check.
- **Honesty (must-hold):** a below-threshold vision "yes" **never advances**. A
  `.visualState` step keeps the `userConfirmation` remediation fallback after the
  observe window. Record completion provenance **distinctly** from a deterministic
  system read — vision self-verification is weaker evidence than reading
  `AppleInterfaceStyle`. Add `CompletionProvenance.visionObserved` (or a telemetry
  tag) so mastery/M4 never treats "the model thought it looked done" as ground truth.
- **Metering:** every `verifyAsync` call is a metered vision spend (QuotaService).
  This is why change-gating + cadence throttle matter.

**WS1 alone upgrades every existing and future lesson** — it's shippable and
testable on a single hand-authored FL-Studio lesson before any ingestion work.

### WS2 · Tutorial → lesson authoring (ingestion)

Turn a tutorial into a runnable `steps.json`.

- **Inputs:** (a) plain "how do I …" prompt (closest to today's Create-a-Skill);
  (b) a YouTube URL → `youtube_transcript`; (c) optionally sampled video frames as
  grounding hints for target descriptions.
- **Author** (new `ClaudeService.authorLesson(...)`): emit a `SkillStepsDTO` +
  `SKILL.md`, one step per action, each with: `instruction`, a natural-language
  `target` description, a `successCheck` — **prefer `.visualState` with a concrete
  visible outcome**, fall back to `userConfirmation` when nothing is observable —
  `remediation`, and `action`. Constrain the model to only the supported
  `successCheck`/`action` types; `loadSkill` already rejects anything unsupported.
- **Write + validate:** reuse the `SkillCatalog` bundle-write path (as in
  `seedBuiltinsIfNeeded`), into the Skills dir, `scaffolded: true`. The manifest
  already carries `scaffolded` → surfaced as **"Unverified"** until a real grounded
  run, which is exactly the right trust posture for machine-authored lessons.
- **Safety (existing rule kept):** never bake the user's private content into a
  `.type` step; a step needing the user's own data stays a `.click` that focuses the
  field and hands back. Set `domainApp` to the tutorial's app so grounding stays
  honest (a target resolving to a different app = mis-ground → ASK).

### WS3 · Video↔app orchestration (the "video, program" loop)

- **Two surfaces:** open the tutorial (reuse `play_video`/`BrowserService`) in one
  window; run the lesson HUD + annotations over the target app (the engine already
  collapses the island and keeps the screen-top clear — `TeachingEngine.start`).
- **v1 scope:** coach from the *authored* steps with the tutorial merely available
  alongside — **no frame-accurate video sync**. WS1's periodic capture is the only
  "continuous watching" needed. Per-step tutorial segmentation / auto-pause is a
  stretch (LA-3), not v1. Real-time video-following is explicitly **out of scope**.

## 4. Phasing

- **LA-0 — `visualState` + async/throttled/metered observer + distinct provenance
  (WS1).** Flag-gated. Prove on a hand-written FL-Studio "add a loop" lesson.
- **LA-1 — `authorLesson` from a text prompt → steps.json (WS2 sans video).** Reuses
  Create-a-Skill UX; produces a `scaffolded` lesson.
- **LA-2 — YouTube URL → transcript → authored lesson (WS2 full) + open-tutorial-
  alongside (WS3 minimal).**
- **LA-3 (stretch) — per-step tutorial segmentation / attention flip.**

## 5. Invariants & risks (must-hold)

- **Wrong-but-invisible is forbidden.** A low-confidence vision verdict must not
  advance a step; ambiguity → keep observing, then offer `userConfirmation`.
- **Vision evidence is second-class.** Recorded distinctly; consider a *higher*
  advance threshold for autonomous mode than for guided.
- **Cost is bounded.** Vision checks are metered, cadence-throttled, and frame-diff
  gated.
- **Scaffolded ≠ verified.** Authored lessons stay "Unverified" until a grounded run.
- **Grounding scope unchanged.** Single-point/UI-first is sufficient for the DAW
  case; multi-region content labeling (the geometry-overlay demo) is *not* in scope.

## 6. Success gate (before trusting vision to advance unattended)

Reuse the guidance evidence funnel (`GuidanceEvidenceService`). Promotion of LA-0
requires a **measured** vision-verify precision on a labeled set (target ≥ ~90%
agreement with ground truth) and a **false-advance rate ≈ 0**, plus per-step
grounded% and lesson-completion. No new trust without runtime evidence
(consistent with the architecture-freeze / evidence-gate discipline).

## 7. Open questions

1. Which model backs `verifyAsync` — reuse `ElementLocationDetector`'s vision model
   or a cheaper yes/no classifier?
2. Confidence thresholds: advance vs. ask; guided vs. autonomous.
3. Does autonomous mode get to advance on a vision verdict in v1, or is vision
   guided-only until precision is proven?
