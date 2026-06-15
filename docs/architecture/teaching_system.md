# Mira Teaching System — Architecture Spec

> **Canonical source:** This file is the authoritative record. The Claude memory store is a working cache. When the two diverge, this file wins.

**Status: M0–M4 BUILT; M5 in progress.** Spec authored 2026-06-13; build through M4 verified on a live Xcode run. As of 2026-06-14: a real drop-in lesson (`reminders-new-reminder`) is authored and run-verified end-to-end, and the **namespace future-proofing layer** is built — a registry of every installed app + the Composio catalog (`_registry.json`) and an on-demand `LessonScaffolder` that generates a `scaffolded: true` starter for any app, shown as **Unverified** until a real grounded run proves the ring lands. A new `step_grounded` telemetry event now journals whether each ringed target actually landed, closing a wrong-but-invisible hole (a silent mis-ground was previously unrecorded). Implementation is still gated milestone-by-milestone (see [Milestones & evidence gates](#milestones--evidence-gates)); M5 numbers require live runs that have not all been collected yet.

---

## What this is

Mira today can point at one element on screen (`PointToService` arcs a triangle to a coordinate produced by `ElementLocationDetector`). This spec extends that into a **live teaching system**: Mira draws and annotates on screen to guide a user through real tasks in real apps — coding, FL Studio, CapCut, filling out forms — while tracking the learner's skill, mastery, and resume point, and packaging each domain as a loadable **Skill** (progressive disclosure, the way Claude Agent Skills work).

**The system in one sentence:**
A teaching loop where every instruction is grounded in an observed screen state, every claim of progress is backed by a recorded observation, and every domain is a swappable evidence-bearing Skill bundle.

---

## The governing invariant

This subsystem inherits the meta-invariant from [architecture_principles.md](architecture_principles.md):

> If a rule can be broken without being recorded, it is not an invariant.
> wrong but invisible → forbidden

For teaching, the same rule takes a sharper form. A teacher's failures are claims:

> **claimed but unobserved → forbidden.**

Mira may not:
- **point** at an element it has not grounded to an observed location,
- **advance** a step it has not observed the user complete,
- **assert mastery** it has not derived from recorded observations,
- **promise** an outcome or a timeline it cannot back with evidence.

When Mira cannot ground a claim, the correct behavior is **not silence and not a guess** — it is to surface the uncertainty and ask:

> *"I'm not certain what's on screen here — can you confirm / show me?"*

This is what makes Mira trustworthy as a teacher. It is also the hardest engineering constraint in this document, and every subsystem below carries a gate that enforces it.

---

## Subsystems

```
            ┌─────────────────────────────────────────────┐
            │              Skill (domain bundle)           │  ← progressive disclosure
            │   manifest · curriculum · elements · annots  │
            └───────────────┬─────────────────────────────┘
                            │ loaded when relevant
            ┌───────────────▼─────────────────────────────┐
            │             Teaching Engine                  │  ← lesson runtime: step → check → advance
            └───┬───────────────┬───────────────┬──────────┘
                │               │               │
   ┌────────────▼───┐  ┌────────▼────────┐  ┌───▼────────────────┐
   │ Element        │  │ Annotation      │  │ Learner Model      │
   │ Grounding      │  │ Canvas          │  │ (append-only       │
   │ (AX / vision   │  │ (overlay draw   │  │  journal + derived │
   │  + gate)       │  │  vocabulary)    │  │  mastery)          │
   └────────┬───────┘  └─────────────────┘  └────────────────────┘
            │
   ┌────────▼───────────────────────────────────────────────────┐
   │ Evidence layer — TelemetryService journal (already exists)  │
   └────────────────────────────────────────────────────────────┘
```

### 1. Annotation Canvas

**Purpose:** the live drawing surface. Generalizes `PointToService`'s transparent, click-through overlay window from "one triangle to one point" into a persistent canvas with a fixed vocabulary of primitives.

**Grounds in:** `PointToService` (overlay window + SwiftUI hosting + animation), `OverlayWindowController`.

**Primitive vocabulary** — all positioned in **normalized coordinates** (0–1, top-left origin), the same space `ElementLocationDetector.normalizedPoint(...)` already produces, so multi-display correctness is inherited for free:

| Primitive | Params | Use |
|---|---|---|
| `arrow(to:)` | target point, optional label | "click here" |
| `ring(around:)` | target point, radius | highlight a control |
| `box(rect:)` | normalized rect | highlight a region/panel |
| `badge(at:number:)` | point, step index | numbered multi-step sequences |
| `callout(at:text:)` | anchor point, short text | inline explanation |
| `spotlight(focus:)` | target rect | dim everything except the target |
| `ghostPath(points:)` | ordered points | demonstrate a drag/motion |

**Honesty gate:** the canvas renders **only** what the Teaching Engine hands it, and the Engine only hands it grounded targets (see §2). The canvas itself never invents a position. A primitive with an ungrounded target is a programming error, not a runtime fallback.

**Out of scope for v1:** freehand pen input from the user, collaborative ink, recording/replay. The vocabulary above is closed until evidence shows a real task needs more.

### 2. Element Grounding

**Purpose:** turn a *named* target ("the snap-to-grid toggle") into a *verified* on-screen location, or honestly report that it can't.

**Grounds in:** `ElementLocationDetector` (Computer Use vision path, now returns `.located / .noElement / .failed`).

**Tiers, best-available:**

1. **Accessibility tree (AX)** — for apps that expose it (native apps, browsers, most forms). Exact bounds, cheap, reliable. Preferred.
2. **Computer Use vision** — for apps that draw custom UI with no AX (FL Studio, CapCut). Returns a coordinate. Lower trust.
3. **No grounding** — neither tier produced a confident location.

**Result type:**

```swift
struct GroundingResult {
    enum Source { case accessibility, vision, none }
    let target:     NamedTarget
    let location:   CGRect?        // normalized; nil when source == .none
    let source:     Source
    let confidence: Double         // 0–1
}
```

**The gate (the heart of the honesty invariant):**

```
confidence ≥ threshold  → annotate + instruct normally
confidence <  threshold  → DO NOT annotate.
                          Degrade to a text instruction and ASK the user
                          to confirm / point, recording groundedBy = .userConfirmation.
source == .none          → never draw. Ask, or tell the user the step can't
                          be auto-guided here.
```

There is no path where Mira draws an arrow at a location it isn't confident about. The `.noElement` vs `.failed` distinction we already built feeds this: `.noElement` ("nothing to point at") is a valid teaching state; `.failed` ("couldn't tell") routes to the ask path.

### 3. Teaching Engine

**Purpose:** the lesson runtime. Walks the user through a Skill's steps, advancing **only on observed completion.**

**A step:**

```swift
struct TeachingStep {
    let id:           String
    let instruction:  String          // what to tell the user
    let target:       NamedTarget?    // what to ground + annotate (nil = conceptual step)
    let annotation:   AnnotationSpec  // which primitive(s) to draw
    let successCheck: SuccessCheck    // how Mira OBSERVES completion
    let remediation:  String          // shown after a failed check
    let maxAttempts:  Int             // before offering to skip / hand off
}
```

**Success checks — observed, never assumed:**

```swift
enum SuccessCheck {
    case observed(Predicate)      // grounded: field non-empty, file saved, clip on timeline, AX state change
    case userConfirmation         // unobservable by Mira → ask the user, record provenance honestly
    case timeout(seconds: Int)    // last resort for steps with no signal — recorded as weak evidence
}
```

**The loop:**

```
present(step)              → record LearningEvent(.instructed)
ground(step.target)        → gate (§2). If ungrounded: ask, don't point.
draw(step.annotation)
observe(step.successCheck) → record LearningEvent(.attempted) on first user action
   pass → record LearningEvent(.completed, groundedBy: <source>) → advance
   fail → record LearningEvent(.failed) → remediation → retry (≤ maxAttempts)
```

**Honesty gate:** `.completed` is only ever written from an `observed` check or an explicit `userConfirmation`. A step the system cannot observe and the user did not confirm **does not advance to completed** — it stays `attempted` and is surfaced as such. No optimistic advancement.

### 4. Learner Model

**Purpose:** answer, honestly, "what does this user know, how well, and where did they leave off?"

**Design:** identical two-layer model to Phase 15 ([architecture_principles.md](architecture_principles.md), `OutcomeAssessment` → `OutcomeSummary`): an **append-only journal of facts**, with a **derived, recomputable projection** on top. Facts are recorded; conclusions are derived; the projection is never stored as a primary fact.

**Journal fact (append-only, never overwritten):**

```swift
struct LearningEvent {
    let occurredAt:  Date
    let skillId:     String
    let objectiveId: String
    let stepId:      String?
    let type:        EventType   // instructed | attempted | completed | failed | hintRequested | confirmed | abandoned
    let groundedBy:  Provenance  // .observation | .userConfirmation | .timeout | .unknown   ← honesty-critical
    let evidenceRef: String?     // pointer to the observation (e.g. AX snapshot id, screenshot hash) — NOT content
}
```

`groundedBy` is the spine of honest mastery: an `.observation`-grounded completion is strong evidence; `.userConfirmation` is medium; `.timeout` is weak. The journal must be able to tell them apart so the projection can weight them.

**Derived projection (recomputed, never persisted as fact):**

```swift
struct MasteryProjection {
    let skillId:      String
    let objectiveId:  String
    let mastery:      Double          // BKT-style p(known); derived only from journal events
    let confidence:   Confidence      // function of evidence COUNT and PROVENANCE quality, not of mastery
    let lastPosition: Resume          // (objectiveId, stepId) — the resume point
    let reviewDue:    Bool            // time-decay since last observed success
}
```

**What this gives, honestly:**
- **skill level / mastery** = derived from observed completions, not self-report;
- **resume point** = last journal position (`lastPosition`);
- **what to review** = objectives with weak or time-decayed evidence (`reviewDue`).

**Honesty gate:** Mira never states a mastery level for an objective with zero journal events. "No evidence" renders as "not yet assessed," never as a guess. `confidence` is metadata about evidence quality (20 observed completions ≠ 20 timeouts), exactly as `assessmentConfidence` works in Phase 15.

**Mastery estimation is deliberately simple to start** (per-objective Bayesian Knowledge Tracing). It is a projection — replaceable without touching the journal. See [Open questions](#open-questions--honest-unknowns).

### 5. Skills — Claude-style domain bundles

**Purpose:** make each domain (forms, coding, FL Studio, CapCut, …) a self-contained, loadable package, so new domains are **new bundles, not core changes**. Directly modeled on Claude Agent Skills: a manifest with a name + description is always in context; the full bundle loads only when relevant (**progressive disclosure**, model-/context-invoked).

**Bundle layout:**

```
skills/
  fl-studio-beats/
    SKILL.md            ← manifest: always-loaded metadata
    curriculum.yaml     ← objectives → steps (TeachingStep), with grounded success checks
    elements/           ← NamedTarget catalog: how to find/verify each ("snap toggle", "channel rack")
    annotations/        ← reusable AnnotationSpec routines for this app
    resources/          ← reference material, optional scripts
```

**`SKILL.md` frontmatter (the always-loaded part):**

```yaml
---
name: fl-studio-beats
description: >
  Teach beat-making and mixing in FL Studio — channel rack, piano roll,
  mixer, automation. Use when the user is in FL Studio or asks to learn beats.
domainApp: com.image-line.flstudio     # bundle id / process match → context trigger
grounding: vision                       # this app has no usable AX tree
version: 0.1.0
---
```

**Relevance / disclosure:** Mira keeps every Skill's `name` + `description` in context. When the active app matches `domainApp`, or the user's request matches a description, Mira loads that Skill's full `curriculum.yaml` and `elements/`. Nothing else is loaded. This is the same mechanism that keeps Claude's own skill list cheap until a skill is actually needed.

**Honesty gate:** a Skill declares its `grounding` tier up front. A `grounding: vision` skill (FL Studio) is honest that it relies on the lower-trust tier, and its success checks must be authored accordingly (more `userConfirmation`, fewer silent `observed` advances). A Skill may not declare an `observed` success check for a state Mira cannot actually read.

---

## Evidence model

The teaching loop extends the guidance funnel already shipped (`GuidanceEvidenceService`: `asked → pointed → acted`). The learning funnel adds two stages:

```
instructed → attempted → completed → retained
```

| Drop-off | Indicated failure |
|---|---|
| instructed → attempted low | instruction unclear, or target couldn't be grounded (user never tried) |
| attempted → completed low | step is too hard, or remediation is wrong |
| completed → retained low | learning didn't stick — mastery model over-credits |

Per the Phase 15 rule (**funnel before score**): build the funnel first. A composite "teaching quality" score, if ever built, must decompose back into these stages. No score before the journal has real learning history.

---

## Failure taxonomy — every incorrectness maps to a detectable state

This is the closure condition ([README.md](README.md): *"A system is complete when every class of incorrectness maps to a detectable state."*) applied to teaching. Each row must resolve to a recorded, reconstructible state — never a silent wrong.

| Failure | Detectable state |
|---|---|
| Pointed at an absent / wrong element | Grounding gate (§2) blocks the draw; `groundedBy=.unknown` or low-confidence recorded; ask path taken |
| Advanced a step the user didn't do | Forbidden by §3 — `.completed` requires `observed` or `userConfirmation`; otherwise stays `.attempted` |
| Claimed mastery never measured | Mastery is derived only from journal events; zero events → "not yet assessed," never a number |
| False promise (time/outcome) | Policy: no time/outcome assertions; framed in objectives + observed progress only |
| Hallucinated instruction (told user to click X that isn't there) | `ElementLocationDetector` `.noElement`/`.failed` + grounding gate; never silently rendered |
| Unobservable completion silently assumed | Disallowed; falls to `userConfirmation`, recorded with that provenance |

If any teaching action produces a result with no traceable journal evidence, the honesty invariant is not real — same standard as the Attack Harness.

---

## Coordinate & grounding model

- **One coordinate space:** normalized 0–1, top-left origin. Every primitive, target, and grounding result lives here. Conversion to/from AppKit global points happens once, at the edges (`ElementLocationDetector.normalizedPoint`, the overlay window). This is why annotations are multi-display-correct without per-feature work.
- **Grounding provenance travels with the location** (`GroundingResult.source`) all the way into the `LearningEvent.groundedBy`, so the learner model can weight evidence by how it was obtained.

---

## Milestones & evidence gates

Each milestone is gated by evidence from the prior one — the [architecture freeze rule](architecture_principles.md): do not extend when design certainty already exceeds runtime evidence.

| # | Deliverable | Evidence gate to advance |
|---|---|---|
| **M0** ✅ | Guidance evidence funnel (`asked → pointed → acted`) — **shipped 2026-06-13** | actOnRate measurable on real Point-and-Ask use |
| **M1** | Annotation Canvas (arrow, ring, badge) + Grounding gate on `ElementLocationDetector` | Draws only grounded targets; never points at `.failed`; verified on real tasks |
| **M2** | Teaching Engine + **one hardcoded mini-skill** (3 steps, 1 app), incl. the "can't ground → ask" path | Loop completes honestly on N real runs; no optimistic advances in the journal |
| **M3** | Skill bundle format + loader (progressive disclosure); migrate the M2 skill into a bundle | A second domain can be added as a bundle with zero core changes |
| **M4** | Learner Model journal + derived mastery + resume | Resume works across sessions; mastery only shown where evidence exists |
| **M5** | Multi-domain Skills (forms / coding / FL Studio / CapCut) + mastery validation | `completed → retained` measurable; mastery estimates track real re-test performance |

**What NOT to build yet:**
- No mastery scoring before the learner journal holds real data (M4 before M5 numbers).
- No second domain before the loop holds on one (M2 before M3).
- No `grounding: vision` skill (FL Studio/CapCut) as the *first* proof — prove the loop on an AX-groundable domain (forms/coding) first, where success checks are observable.

---

## Open questions — honest unknowns

In the spirit of the invariant, the parts that are genuinely uncertain, named rather than hidden:

1. **Vision grounding reliability on custom UIs.** FL Studio and CapCut have little/no AX. How often can Computer Use vision locate a named control accurately enough to draw on it? Unknown until measured. This is why those domains are last, not first.
2. **Mastery validity with sparse data.** BKT needs repeated observations per objective. Early on, evidence is thin; the projection must express low `confidence` honestly rather than overclaim. Whether the estimate tracks real retention is an M5 validation question, not an assumption.
3. **Success-check coverage.** Some completions are simply not observable (a creative judgment, a subjective mix). Those *must* fall back to `userConfirmation` — the open question is how large that fraction is per domain, and whether a domain with mostly-unobservable steps can be taught honestly at all, or only coached.
4. **Annotation legibility vs. occlusion.** Drawing over a live app risks covering the very thing the user needs. The `spotlight` primitive and self-occlusion handling (already fixed once for the screen-guidance overlay) need re-validation per primitive.

None of these block M1–M2; all of them must be answered with runtime evidence before the system claims to be "the best teacher."

---

## Relationship to the rest of the architecture

- Inherits the meta-invariant and two-layer (fact/projection) model from [architecture_principles.md](architecture_principles.md).
- Reuses the journal-as-truth, funnel-before-score discipline from Phase 15.
- Holds itself to the same "no silent wrong" standard as [attack_harness.md](attack_harness.md).
- Does not touch Phase 14 governance, the invariant set, or any existing authority mechanism.
