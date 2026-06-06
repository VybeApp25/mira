# Phase 14 Governance — COMPLETE

> **Canonical source:** This file is the authoritative record. The Claude memory store is a working cache. When the two diverge, this file wins.

**Status: Complete. All wiring done. All invariants enforced in production code.**

Phase 14 implemented the architecture invariant: "No governance decision may depend on a view lifecycle." It is now a closed, verifiable, crash-recoverable governance loop.

See [architecture_principles.md](architecture_principles.md) for the full invariant set and Phase 14 closure section.

---

## What was wrong (pre-Phase 14)

`delegationAuthorized` depended on `observeEvidenceStrength()` being called from `.onAppear` in `ProposalMetricsView`. If the dashboard never opened, governance state did not update. Authority was partially maintained by a UI event, not by journal evidence.

**Headless test (pre-Phase 14):** If the dashboard never opens for 30 days, does governance remain correct? **No.**

**Recovery test (pre-Phase 14):** If the process crashes mid-evaluation, can authority be reconstructed from journal state? **Partial.**

**Determinism test (pre-Phase 14):** Given identical journal state, does governance always produce identical results? **Not guaranteed** — time-windowed metrics could vary with `Date.now()`.

---

## What was built (Phase 14 implementation)

### EvidenceEvaluator (`Mira/Services/EvidenceEvaluator.swift`)

Pure stateless function. No side effects, no scheduling, no UI dependency, no `@MainActor`. Two hard invariants enforced at the file level and verified by `runIsolationVerification()`:

1. `BackgroundScheduler` must not compute any governance signal directly — all governance comes from `EvidenceEvaluator` output.
2. `Date()` is never called inside this file — the `anchor` parameter is the sole time reference.

### EvidenceSnapshot (`Mira/Models/ProposalModels.swift`)

Journal record type. `createdAt` is the TimeAnchor — all governance derivations anchor to this field, never to wall-clock time. `delegationAllowed()` is the single authoritative derivation point for authority — never a stored `Bool` flag.

### ProjectEngine snapshot storage (`Mira/Services/ProjectEngine.swift`)

- `latestEvidenceSnapshot: EvidenceSnapshot?` — `@Published`, persisted to `evidence_snapshot.json`
- `recordEvidenceSnapshot(_:)` — single write path, called only by `BackgroundScheduler`
- `loadSnapshot()` runs in `init()` — governance state survives process restarts before any session begins

### BackgroundScheduler wiring (`Mira/Services/BackgroundScheduler.swift`)

After every checkpoint save, the scheduler: loads all proposals across all projects → calls `EvidenceEvaluator.evaluate(proposals:anchor:)` with `Date()` as the anchor (the scheduler fire time is the legitimate anchor) → calls `ProjectEngine.recordEvidenceSnapshot(_:)`. Under `#if DEBUG`, `runIsolationVerification()` runs after every write — fail-fast guard that the evaluator hasn't drifted toward runtime dependencies.

### ProposalMetricsView decoupling (`Mira/Views/ProposalMetricsView.swift`)

- `.onAppear` body removed — `loadDelegationState()` and `observeEvidenceStrength()` are gone from every call site outside `ProposalStore` itself
- `regressionLockRow` reads `engine.latestEvidenceSnapshot` exclusively; `delegationAllowed()` is the only derivation path; the manual "Authorize" button is removed — authority is earned from evidence, not granted by gesture

---

## Phase 14 correctness tests — all passing

**Headless:** If Mira runs for 90 days with no UI ever opened, does governance remain correct?
**Yes.** `BackgroundScheduler` writes snapshots on schedule; no `.onAppear` participates.

**Recovery:** If Mira crashes mid-evaluation, can authority be reconstructed from journal state?
**Yes.** `loadSnapshot()` runs in `ProjectEngine.init()`. Worst case: the snapshot from the prior scheduler tick is used (safe degradation). No persisted flag can disagree with the journal.

**Determinism:** Given identical journal state, does governance always produce identical results?
**Yes.** `EvidenceEvaluator` never calls `Date()`. All time-windowed metrics anchor to `proposal.reviewedAt` (journal data). The anchor is injected by the caller and becomes `EvidenceSnapshot.createdAt`.

---

## Phase 14 outcome

- `EvidenceEvaluator` is the sole derivation layer for authority
- `BackgroundScheduler` is the sole producer of evidence snapshots
- UI is fully decoupled from governance logic
- Delegation is fully derived from journal state
- No silent governance failure is possible in the authority path

---

## Attack harness status — PASS (2026-06-05)

All 17 cells in the attack matrix (see [attack_harness.md](attack_harness.md)) resolved by the Phase 14 implementation. Attack pass executed 2026-06-05. Zero silent failures. All violations structurally impossible or explicitly confirmed PASS under direct attack. `runIsolationVerification()` provides continuous regression detection in debug builds.

---

> **Regression boundary:** Phase 14 is complete. Any future change that reintroduces UI-derived authority, `Date()`-dependent evaluation outside `BackgroundScheduler`, or stored delegation flags constitutes a regression of the governance model and must be rejected at review time.
