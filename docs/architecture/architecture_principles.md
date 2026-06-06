# Mira Architecture Principles

> **Canonical source:** This file is the authoritative record. The Claude memory store is a working cache. When the two diverge, this file wins.

These principles weren't designed up front — they were discovered by observing what survived across Phases 1–13B without introducing new complexity.

---

## The journal's role at each phase

| Phase  | Journal Role              | Status    |
|--------|---------------------------|-----------|
| 1–7    | Persistence               | Complete  |
| 8–10   | Retrieval                 | Complete  |
| 11–12  | Coordination              | Complete  |
| 13A    | Evaluation                | Complete  |
| 13B    | Judgment calibration      | Complete  |
| 14     | Evidence-driven authority | **Complete** |
| 13C    | Delegated execution       | Pending evidence gate |
| Future | Authority management      | —         |

**You can't skip a layer without creating a trust gap.** Each layer produces the evidence that the next layer requires. This is why the phased approach isn't preference — it's the mechanism that prevents autonomy from outrunning its own justification.

Phase 13A created the first feedback loop: Agent → Journal → Quality Measurement → Future Agent Permissions. Before 13A, the journal was passive storage. After it, the journal has an opinion about whether behavior was good — and that opinion gates future capability.

The journal is becoming the mechanism that determines how much authority the system deserves.

---

## What this system now is (epistemic status)

This is not a journal system, a coordination layer, a scheduler, or a proposal pipeline. It is:

> A closed-loop system where authority is only granted through adversarially verified evidence.

**The epistemic shift that occurred at Phase 14 preflight:**

Before: "If the system behaves correctly in normal operation, it is correct."

Now: "If the system survives constructed failure without silent deviation, it is correct."

Correctness is defined not by success paths, not by happy-path execution, not by observed behavior — but by resistance to intentional invalidation attempts.

**The formal closure condition:**

> A system is complete when every class of incorrectness maps to a detectable state.

Which means:
- "wrong but invisible" → forbidden
- "wrong but recoverable" → acceptable
- "wrong but recorded" → acceptable
- "wrong and indistinguishable from correct" → not allowed under this architecture

**Current operational status:** The system is no longer evolving in capability space. It is operating in proof space. Future work is only: reducing false positives in the harness, expanding adversarial coverage, tightening invariants into fewer primitives, or scaling evidence volume. The nature of correctness itself is not changing.

**The 17-cell attack harness is not a test suite.** It is a completeness proof attempt over failure space — attack cells enumerate minimal representatives of each violation class, and the system must map every violation to a recorded outcome. That is closer to formal methods than application testing. See [attack_harness.md](attack_harness.md).

**The shift from architecture to verification regime:**

Everything through Phase 13 was designing behavior — components, invariants, flows, coordination layers. Everything from the Attack Harness onward is different in kind:

> You are no longer designing behavior. You are defining acceptable failure space.

The four-state closure model is not a correctness constraint. It is a **completeness constraint on observability**:

> The system is allowed to fail — but never allowed to fail silently or ambiguously.

This produces a hidden structural property: there is no "unknown unknown" state inside the runtime. There is no hidden divergence between layers. There is no cached authority that can drift silently. This is **observability completeness over all governance-relevant state transitions**.

Most systems aim for correctness under expected conditions. This system is built toward detectability under adversarial conditions. That difference is what turns "a well-structured system" into "a system that can be reasoned about under failure."

**Final layer map (complete system state as of Phase 13B):**

| Layer | Role |
|---|---|
| Journal | Immutable truth substrate |
| Compute | Pure derivation layer |
| UI | Projection only |
| Scheduler | Trigger mechanism only |
| Coordinator | Routing layer only |
| Governance | Derived evidence state |
| Attack Harness | Correctness verifier |
| Invariants | Failure class boundaries |

**Possible future direction (not required):** A formal mapping of all system states → allowed / disallowed / recoverable, turning Mira into a constrained state machine with an evidence-backed transition system. That would be the next artifact if correctness needs to be tightened further into formal methods territory.

---

## The invariant that held across every phase

**Journal = truth. Compute = view.**

Every new capability was added by reading more from the journal, not by creating a parallel state system. This kept complexity growth linear rather than exponential — new features don't introduce new sources of truth.

- Phase 8: history queries
- Phase 11: scheduler decisions from journal state
- Phase 12: coordination decisions from journal state
- Phase 13A: quality scoring over journal output
- Phase 13B: approval metrics from journal decisions
- Phase 13C gates: derived from accumulated journal evidence

**How to apply:** When a new feature is proposed, ask: "Is this reading from the journal, or is it creating a new source of truth?" If the latter, it needs strong justification.

## The single-writer invariant

`ProjectEngine` is `@MainActor final class`. All state transitions serialize through it. Coordination sits *above* the journal, not beside it:

```
Agents → AgentCoordinator → ProjectEngine (@MainActor) → Journal
```

This is why Phase 12 never became a distributed-systems problem. The chaos simulations produced deterministic outcomes because there was never a race condition to hunt.

**How to apply:** Never split journal writes across multiple writers, even for performance. The serialization cost is the correctness guarantee.

## Opaque decisions get replaced with observable evidence

This happened at every layer:
- `SessionTrigger` explained why a session existed
- `CoordinationTrace` explained why an agent was selected
- `PreemptionDecision` explained why a task was interrupted
- Gate breakdown explained why 13C promotion is blocked

The pattern: replace "Gate: FAIL" with "✗ Rejection rate: 18% (≤15%)". The system keeps becoming more self-explaining through journal data rather than requiring interpretation from memory or intuition.

## Phase 13A introduced measurement, not just recording

Before 13A: Agent produces output → Journal records output.
After 13A: Agent produces output → Journal records output → Journal evaluates output quality (specificity score).

This is the moment the system started evaluating its own AI layer. The specificity score is the first place where the journal has an opinion about whether the agent's behavior was good.

## The approval dataset is more valuable than the proposals

The proposal artifacts are useful. The approval/rejection history with context, latency, and notes is the strategic asset. Over time it becomes a structured judgment corpus specific to Mira's environment — the evidence source that determines whether and how much autonomy to extend.

---

## Invariant: No governance decision may depend on a view lifecycle

**Rationale (discovered, not designed):** The system already learned this lesson three times:
- `WakeWordService` moved from view lifetime → application lifetime
- Scheduling moved from UI observation → journal queries
- Session priority moved from HUD state → ProjectEngine truth

Governance must follow the same path. The correct authority chain is:

```
BackgroundScheduler
    ↓
EvidenceEvaluator
    ↓
EvidenceSnapshot written to journal
    ↓
DelegationAuthority derived
    ↓
Dashboard renders state
```

Never:

```
Dashboard opens
    ↓
Governance recalculated
    ↓
Authority changes
```

This invariant applies to every Phase 14+ feature: governance, delegation, trustworthiness, calibration, autonomy limits, and future agent permissions. **The runtime owns them. The dashboard only explains them.**

**Headless Correctness Test (use at every architecture review):**

> If Mira runs for 90 days with no UI ever opened, would governance, authority, delegation status, evidence strength, and revocation all remain correct?

If yes → the design belongs in the runtime. If no → truth still lives in presentation. That is the failure condition.

**Recovery Correctness Test (use alongside Headless at every architecture review):**

> If Mira crashes at any point during governance evaluation, can authority be reconstructed entirely from journal state after restart?

The crash can occur anywhere in the chain:

```
BackgroundScheduler → EvidenceEvaluator → (crash) → EvidenceSnapshot write
```

or:

```
EvidenceSnapshot written → (crash) → DelegationAuthority recalculated
```

The required recovery path is always:

```
recoverGovernanceState()
    ↓
read latest EvidenceSnapshot
    ↓
derive authority
    ↓
continue
```

**The rule this encodes:** Authority is derived state, not stored state. If the journal contains enough information to recompute authority, recomputation always wins over any persisted flag. A persisted `delegationAuthorized` flag that can disagree with the journal must never be treated as authoritative.

This gives governance the same crash-recovery guarantees already present in project sessions, checkpoints, proposal history, and assignment coordination. The pattern is identical everywhere:

```
Journal survives → Runtime reconstructs → UI renders
```

Never:

```
Runtime flag survives → Journal disagrees → Runtime wins
```

**Determinism Test (use alongside Headless + Recovery at every architecture review):**

> Given identical journal state, governance evaluation must always produce identical results regardless of evaluation timing, number of UI sessions open, scheduler frequency, background activity timing, or prior dashboard access.

The formal requirement:

```
GovernanceResult = f(JournalState only)
```

Not:

```
GovernanceResult = f(JournalState + Runtime + Timing + UI)
```

**Why this is a real risk in this system specifically:** Evidence metrics like "last 20 proposals," "last 7 days," and "recent stability" can accidentally depend on *when* evaluation runs rather than *what the journal contains*. If time windows are evaluated against `Date.now()` rather than against a fixed snapshot timestamp, the same journal produces different governance outputs depending on when the evaluator runs.

**The rule this encodes:** If the journal is frozen, governance output is frozen. Temporal variance is a hidden dependency on execution context, not on journal truth. All time-windowed metrics must be evaluated relative to the `EvidenceSnapshot.createdAt` timestamp or a similarly journal-anchored reference, never against the current clock.

**What the three tests together cover:**
- Headless: Can the system run without a UI?
- Recovery: Can the system recover without trusting memory?
- Determinism: Given the same journal, does evaluation always produce the same result?

---

## The four locked invariants — closure condition for Phase 14+

These are the complete invariants of the journal-driven governance system:

| Invariant | Eliminates |
|---|---|
| **Headless Correctness** | UI dependency |
| **Recovery Correctness** | Runtime-memory dependency |
| **Determinism** | Timing / execution-context dependency |
| **Journal Authority** | External state dependency |

**Closure condition:** A governance feature that satisfies all four belongs fully in the runtime. A feature that fails any one still has truth living somewhere outside the journal. Everything after this closure is scaling evidence volume, not changing the model.

**The final form of the journal philosophy:**

> Truth lives in the runtime. Views are explanations of truth. Never the source of it.

**How to apply:** Before accepting any Phase 14+ proposal, apply all three tests. If any answer is "no" for any governance, delegation, or autonomy feature, reject or redesign before implementation begins.

---

## Phase 14 preflight: Failure-mode attack pass

This is not feature work. It is adversarial validation — the step that turns "close to correct" into "provably correct."

**The central question of the attack pass:**

> Can this system be made to lie without leaving evidence in the journal?

If the answer is yes for any invariant, that invariant is not yet real.

**The meta-invariant that governs the attack pass:**

> If a rule can be broken without being recorded, it is not an invariant.

Violations must surface in exactly one of three ways:
1. Rejected at design time (the architecture makes the violation impossible to construct)
2. Explicit guard failure at runtime (a named, catchable error — not a silent wrong result)
3. Deterministic recomputation mismatch (recovery re-derives authority and the discrepancy is visible in the journal)

"Silent correctness" — a violation that produces no evidence — is the only failure mode the journal architecture cannot recover from. It is the one thing the attack pass is designed to find.

**Attack axes (one per invariant):**

| Invariant | Attack to construct |
|---|---|
| Headless | Force governance state to change without any journal write occurring |
| Recovery | Produce a persisted `delegationAuthorized` flag that disagrees with a re-derived value after restart |
| Determinism | Feed the same `EvidenceSnapshot` to `EvidenceEvaluator` twice at different wall-clock times and get different results |
| Journal Authority | Reach a `delegationAuthorized = true` state that cannot be traced back to any `EvidenceSnapshot` in the journal |

**What passing looks like:** For each attack, the system either rejects it structurally (the code makes it impossible) or the violation is legible in the journal. No attack should produce a governance outcome that a post-hoc journal reader could not reconstruct and explain.

**When to run:** Before any Phase 14 delegation or autonomy capability is wired to real filesystem writes. The attack pass is the gate between evidence infrastructure and live authority.

**Pass condition:** All 17 cells in the attack matrix resolve. Zero produce silent failures. See [attack_harness.md](attack_harness.md) for the full matrix.

---

## Trust questions become evidence questions

The architecture never relied on trust as a prerequisite. It converted trust questions into evidence questions:
- "Can background work run?" → session provenance
- "Can agents coordinate?" → assignment traces
- "Are checkpoints useful?" → specificity scores
- "Are proposals good?" → approval metrics
- "Can writes be allowed?" → demonstrated proposal performance

**The future progression:**
```
Evidence → Permission        (current: 13C gate)
Evidence → Confidence        (next: per-domain trust scores)
Evidence → Delegation        (future: authority earned statistically)
```

Not: "Can Mira do this?" But: "How much authority has Mira statistically earned in this domain?"

That is a different category of system. The journal stops being an audit log and becomes a calibration mechanism.

---

## Phase 14 — Evidence-Driven Delegation (Complete)

Phase 14 is a closed governance loop. Delegation is derived exclusively from journaled evidence. No UI event, no persisted flag, and no ad-hoc computation participates in any authority decision.

**Sole authority components:**

| Component | Role |
|---|---|
| `BackgroundScheduler` | Only trigger source — provides `Date()` as the anchor |
| `EvidenceEvaluator.evaluate(proposals:anchor:)` | Only authority derivation function — pure, stateless, no side effects |
| `EvidenceSnapshot` | Only persisted governance record — written to `evidence_snapshot.json` |
| `ProjectEngine.latestEvidenceSnapshot` | Only authority read path — loaded on launch for crash recovery |
| `delegationAllowed()` | Only derivation call site — computed, never stored |
| `ProposalMetricsView` | Read-only projection of snapshot state |

**Authority chain (final form):**

```
BackgroundScheduler (time trigger)
    ↓
Proposal generation + checkpointing
    ↓
EvidenceEvaluator.evaluate(proposals, anchor)
    ↓
EvidenceSnapshot (persisted journal state)
    ↓
ProjectEngine.latestEvidenceSnapshot (recovered on restart)
    ↓
delegationAllowed() (derived, not stored)
    ↓
UI (read-only projection)
```

**Phase 14 completion criteria — all satisfied:**

- Determinism invariant: enforced via anchor injection; `EvidenceEvaluator` never calls `Date()` internally
- Recovery invariant: `EvidenceSnapshot` persists to disk; `loadSnapshot()` runs in `ProjectEngine.init()` before any session starts
- Headless invariant: `ProposalMetricsView.onAppear` no longer calls `observeEvidenceStrength` or `loadDelegationState`; removing the dashboard from the process cannot change governance state
- Journal Authority invariant: `delegationAllowed()` is only reachable through `EvidenceSnapshot`; no `UserDefaults` flag, no in-memory `delegationAuthorized` property, participates in any live authority decision
- Isolation verification: `EvidenceEvaluator.runIsolationVerification()` runs on every debug launch and after every scheduler-produced snapshot; crashes immediately on any invariant drift
- **Attack pass: Executed 2026-06-05. All 17 cells PASS. Zero silent failures. Zero FAIL-EXPOSED. Zero FAIL-SAFE. All violations structurally impossible or explicitly confirmed under direct attack. See [attack_harness.md](attack_harness.md) for full execution record.**

**Closure statement:**

> Authority in the system is no longer computed ad hoc. It is reconstructed from a journaled timeline of evidence snapshots.

---

> **Regression boundary:** Phase 14 is complete. Any future change that reintroduces UI-derived authority, `Date()`-dependent evaluation outside `BackgroundScheduler`, or stored delegation flags constitutes a regression of the governance model and must be rejected at review time.
