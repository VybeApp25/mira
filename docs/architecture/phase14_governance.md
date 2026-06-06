# Phase 14 Governance

> **Canonical source:** This file is the authoritative record. The Claude memory store is a working cache. When the two diverge, this file wins.

**This work is the concrete implementation of the architecture invariant: "No governance decision may depend on a view lifecycle."**

See [architecture_principles.md](architecture_principles.md) for the full invariant set.

---

## Required correctness tests before any Phase 14 implementation begins

**Headless:** If Mira runs for 90 days with no UI ever opened, does governance remain correct?
Current answer (pre-Phase 14): No. Required answer: Yes.

**Recovery:** If Mira crashes at any point during governance evaluation, can authority be reconstructed entirely from journal state after restart?
Current answer (pre-Phase 14): Partial. Required answer: Yes, always — recomputation wins over any persisted flag.

**Determinism:** Given identical journal state, does governance evaluation always produce identical results regardless of timing, scheduler frequency, UI sessions open, or background activity?
Current answer (pre-Phase 14): Not guaranteed — time-windowed metrics ("last 7 days", "recent stability") may vary with `Date.now()`. Required answer: Yes — all time windows must anchor to `EvidenceSnapshot.createdAt`, not the current clock.

**Closure condition:** A Phase 14 governance feature belongs in the runtime only when it satisfies all three tests. Failing any one means truth still lives outside the journal.

**Required preflight before wiring delegation to live filesystem writes:** Run the failure-mode attack pass (documented in [attack_harness.md](attack_harness.md)). The attack pass is the gate between evidence infrastructure and real authority. The central question it answers:

> Can this system be made to lie without leaving evidence in the journal?

Every violation must surface as a journal write, an explicit guard failure, or a deterministic recomputation mismatch. Silent correctness — a governance outcome with no traceable journal evidence — is the one failure the architecture cannot recover from.

---

## The gap (current state, pre-Phase 14)

`delegationAuthorized` currently depends on `observeEvidenceStrength()` being called from `.onAppear` in ProposalMetricsView. If the dashboard never opens, governance state doesn't update. Authority is partially maintained by a UI event, not by journal evidence.

**Test:** If the dashboard never opens for 30 days, should governance still remain correct?
Current answer: No. Correct answer: Yes.

---

## The fix (Phase 14)

Move evidence evaluation out of the UI into a periodic journal write:

```swift
struct EvidenceSnapshot: Codable {
    let createdAt:       Date
    let dimensions:      EvidenceDimensions
    let trustworthiness: Double
    // Written by EvidenceEvaluator, not by the UI
}
```

`BackgroundScheduler` already runs every 30 minutes — the natural place to call `EvidenceEvaluator.evaluate()`, which writes an `EvidenceSnapshot` to the journal.

`delegationAuthorized` becomes a pure derived property:
```swift
var delegationAuthorized: Bool {
    guard let snap = latestEvidenceSnapshot else { return false }
    return snap.dimensions.strength == .strong && snap.trustworthiness >= threshold
}
```

The dashboard reads governance state; it does not drive governance state.

---

## Architectural principle restored

Same pattern used everywhere else in the system:
- Journal = truth (EvidenceSnapshot written on schedule)
- Compute = interpretation (delegationAuthorized derived from snapshot)
- UI = presentation (dashboard reads, doesn't write)

Right now governance is mostly correct but the revocation path lives partially in presentation. Phase 14 moves it fully into the evidence layer.

---

## Why it's not a Phase 13 blocker

Phase 13C doesn't exist yet. The regression lock has no real authority to revoke. When 13C is built and delegation actually gates real filesystem writes, this gap becomes critical. That's the right time to fix it — after 13B has produced the evidence pipeline and before 13C is wired to the lock.

**How to apply:** When starting Phase 14 work, begin with EvidenceEvaluator + EvidenceSnapshot before touching any delegation or apply logic. The journal write comes first.
