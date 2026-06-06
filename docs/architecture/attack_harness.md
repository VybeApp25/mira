# Phase 14 Attack Harness

> **Canonical source:** This file is the authoritative record. The Claude memory store is a working cache. When the two diverge, this file wins.

## What this is

The Attack Harness is the last layer between "well-designed system" and "formally adversarially validated system." It operationalizes the meta-invariant from [architecture_principles.md](architecture_principles.md):

> If a rule can be broken without being recorded, it is not an invariant.

Equivalently: **Invariant ⇔ Observability under adversarial conditions.**

This is not feature work. It is proof. Phase 14 delegation may not be wired to live filesystem writes until every cell in this matrix resolves to PASS, FAIL-SAFE, or FAIL-EXPOSED. Silent failure is not a valid outcome.

---

## Outcome definitions

| Outcome | Meaning |
|---|---|
| **PASS** | The violation is structurally impossible — the architecture prevents it from being constructed |
| **FAIL-SAFE** | The violation is detected, blocked, and recorded in the journal |
| **FAIL-EXPOSED** | The violation occurs but leaves unambiguous journal evidence — a post-hoc reader can reconstruct what happened and why |

There is no "silent failure" outcome. If a test produces a governance result with no traceable journal evidence, the invariant is not real.

---

## Attack Matrix

### Invariant 1: Headless Correctness
*No governance decision may depend on a view lifecycle.*

| # | Attack | Expected outcome | Journal assertion |
|---|---|---|---|
| H1 | Close ProposalMetricsView mid-evaluation; verify `delegationAuthorized` still reflects current journal state | PASS or FAIL-SAFE | No governance state delta should exist without a corresponding `EvidenceSnapshot` write |
| H2 | Never open the dashboard for 30 days of simulated background activity; query `delegationAuthorized` | PASS | Authority derived solely from `EvidenceSnapshot` entries; no `.onAppear` call in journal write chain |
| H3 | Open multiple simultaneous dashboard instances; verify governance state is identical across all | PASS | Single `EvidenceSnapshot` source — multiple readers cannot diverge |
| H4 | Force a UI bypass: derive `delegationAuthorized` without calling `EvidenceEvaluator` | FAIL-SAFE | Guard must reject or the discrepancy must appear at next `recoverGovernanceState()` call |

---

### Invariant 2: Recovery Correctness
*Authority is derived state, not stored state. Recomputation always wins over persisted flags.*

| # | Attack | Expected outcome | Journal assertion |
|---|---|---|---|
| R1 | Crash process immediately after `EvidenceSnapshot` write, before `delegationAuthorized` is derived; restart and query | PASS | `recoverGovernanceState()` reads latest snapshot, derives authority — result matches what a full evaluation would have produced |
| R2 | Crash process immediately after `delegationAuthorized` is set to `true`; manually corrupt the persisted flag to `false`; restart | PASS | Recomputation from journal wins; the corrupted persisted flag is ignored or overwritten |
| R3 | Crash process mid-`EvidenceEvaluator` run, before snapshot is written; restart | FAIL-SAFE or PASS | Either prior snapshot is used (safe degradation) or evaluation restarts cleanly; no partial snapshot enters the journal |
| R4 | Force persisted `delegationAuthorized = true` with no corresponding `EvidenceSnapshot` meeting threshold; restart | FAIL-SAFE | `recoverGovernanceState()` re-derives from journal — authority is revoked; the discrepancy is journal-visible |

---

### Invariant 3: Determinism
*Given identical journal state, governance evaluation always produces identical results regardless of execution context.*

| # | Attack | Expected outcome | Journal assertion |
|---|---|---|---|
| D1 | Feed same `EvidenceSnapshot` to `EvidenceEvaluator` at two different wall-clock times separated by 8 days; compare results | PASS | Outputs are bit-for-bit identical; no time-window metric varies with `Date.now()` |
| D2 | Inject a `"last 7 days"` window evaluated against wall clock vs. `EvidenceSnapshot.createdAt`; verify which anchor is used | PASS | All windowed metrics anchor to `snapshot.createdAt`; `Date.now()` is not in the evaluation function signature |
| D3 | Run evaluation with scheduler frequency at 30-minute intervals vs. 5-minute intervals; compare governance outputs for same journal state | PASS | Frequency affects how often snapshots are written, not what they contain when evaluated |
| D4 | Run evaluation once immediately after a burst of proposals vs. once after a quiet period; same journal state both times | PASS | Identical snapshot → identical output; "recent activity" is not a real-time signal |

---

### Invariant 4: Journal Authority
*No `delegationAuthorized = true` state may exist without a traceable `EvidenceSnapshot` in the journal meeting threshold.*

| # | Attack | Expected outcome | Journal assertion |
|---|---|---|---|
| J1 | Set `delegationAuthorized = true` directly in memory without writing an `EvidenceSnapshot`; query journal | FAIL-EXPOSED or FAIL-SAFE | Either the flag is blocked at write time, or `recoverGovernanceState()` immediately reverts it and logs the discrepancy |
| J2 | Approve delegation via a single project with high approval rate but low diversity (fails diversity gate); verify journal | FAIL-SAFE | `diversityScore` below threshold → snapshot records gate failure → authority not granted; no silent pass |
| J3 | Approve delegation with 20 reviews all from one session (volumeScore passes, diversityScore fails); verify journal | FAIL-SAFE | Same as J2 — geometric mean of dimensions prevents single-axis gaming |
| J4 | Revoke delegation by letting `stabilityScore` decay; verify authority is automatically removed without manual intervention | PASS | `BackgroundScheduler` writes new `EvidenceSnapshot`; derived `delegationAuthorized` transitions to `false`; journal shows the decay chain |
| J5 | Attempt to apply a 13C filesystem write with `delegationAuthorized` derived from an expired or stale snapshot | FAIL-SAFE | Apply gate checks snapshot recency; stale snapshots do not authorize writes |

---

## How to run this

This is a pre-implementation spec, not a test suite — the test cases define what to prove, not how to automate it. When Phase 14 implementation begins:

1. For each cell, determine whether the outcome is PASS (structurally impossible) or requires an explicit guard/journal write to achieve FAIL-SAFE or FAIL-EXPOSED
2. Any cell that currently produces "silent failure" is a required fix before that invariant can be claimed
3. The implementation work IS the guards that convert silent failures to FAIL-SAFE or FAIL-EXPOSED outcomes
4. Final validation: a post-hoc journal reader (human or automated) must be able to reconstruct what happened for every FAIL-SAFE and FAIL-EXPOSED outcome

**Pass condition for Phase 14 preflight:** All 17 cells resolve. Zero produce silent failures.

---

## The structural consequence

The system is now a closed correctness lattice where:
- correctness is not assumed
- correctness is not tested occasionally
- correctness is continuously attack-validated through its lifecycle

Phase 14 governance is not "governance implementation" — it is invariant stress validation of a complete correctness lattice. Nothing structural is missing. Only proof remains.
