# Mira Architecture Docs

> **Persistence model:** These files are the canonical, versioned source of truth for Mira's architecture, governance, and correctness model. The Claude memory store (`~/.claude/`) is a working cache — when the two diverge, this repo wins.

---

## Documents

| File | Contents |
|---|---|
| [architecture_principles.md](architecture_principles.md) | Core invariants, phase history, epistemic status, four locked invariants, three correctness tests, verification regime |
| [phase14_governance.md](phase14_governance.md) | Phase 14 implementation plan — moving governance from UI lifecycle to journal-derived authority |
| [attack_harness.md](attack_harness.md) | 17-cell adversarial validation matrix; required preflight before Phase 14 delegation touches live filesystem writes |
| [teaching_system.md](teaching_system.md) | Live annotation + tutoring subsystem spec — honesty invariant ("claimed but unobserved → forbidden"), annotation canvas, element grounding, teaching engine, learner model, Claude-style Skill bundles; milestone gates (SPEC, not built) |

---

## The system in one sentence

A closed-loop system where authority is only granted through adversarially verified evidence.

## The closure condition

> A system is complete when every class of incorrectness maps to a detectable state.

- wrong but invisible → forbidden
- wrong but recoverable → acceptable
- wrong but recorded → acceptable
- wrong and indistinguishable from correct → not allowed

## The four locked invariants

| Invariant | Eliminates |
|---|---|
| Headless Correctness | UI dependency |
| Recovery Correctness | Runtime-memory dependency |
| Determinism | Timing / execution-context dependency |
| Journal Authority | External state dependency |

## The journal philosophy

> Truth lives in the runtime. Views are explanations of truth. Never the source of it.

---

## Keeping this in sync

When architecture memory is updated in a Claude session, mirror the changes here before closing the session and commit. The attack harness is append-only — add cells, never remove them without a documented rationale in the commit message.
