# Implementation Plan — Mira for Windows

This is a phased plan, not an authorization to build. **Phase 0 (this audit) is complete once the user reviews the five documents in this folder.** Nothing past Phase 0 should start without explicit go-ahead, and each phase below should be re-confirmed with the user before it begins — this plan describes a *proposed* sequence, not a committed schedule.

---

## Phase 0 — Audit (this phase)

**Deliverables (done):**
- [WINDOWS_ARCHITECTURE.md](WINDOWS_ARCHITECTURE.md) — layered architecture, shared vs. rewrite boundary, repo layout, tech-stack direction, type-generation strategy.
- [FEATURE_PARITY_MATRIX.md](FEATURE_PARITY_MATRIX.md) — every audited system, macOS mechanism, Windows path, rewrite scope.
- [SECURITY_AND_PRIVACY.md](SECURITY_AND_PRIVACY.md) — secrets architecture, one concrete remediation item (committed cron secret), permission-model gap analysis.
- [REPOSITORY_EVIDENCE.md](REPOSITORY_EVIDENCE.md) — the evidence ledger every other document cites.

**Explicitly not done, and not in scope until the user says otherwise:** any Windows project scaffolding, any code, any dependency installation, any modification to `Mira/`, `Mira.xcodeproj/`, `AgentService/`, or `supabase/`.

**Open items from this audit that should be resolved before Phase 1 is scoped in detail** (see WINDOWS_ARCHITECTURE.md §7 and SECURITY_AND_PRIVACY.md §1):
1. Confirm via `strings` on a built macOS binary whether any provider secret still ships client-side today.
2. Confirm whether Anthropic's `claude` CLI and OpenAI's `codex` CLI have Windows-native builds — this determines whether features 10 and 30 in the parity matrix are portable at all for a v1.
3. Rotate the committed `CRON_SECRET` (independent of Windows work, should happen regardless of what the user decides about the port).
4. A follow-up read of `WebsiteBuilderAgent`/`ResearchAgent`/`ContentAgent`/`PublishingAgent`/`WebsiteHealthAgent` (referenced but not opened in this audit) to determine whether that logic belongs in the shared Node sidecar rather than being reimplemented per-client.

---

## Proposed phase sequence (for discussion, not commitment)

### Phase 1 — Shared contracts + backend verification (no UI)

The lowest-risk, highest-leverage next step, because it touches only the already-shared backend layer and produces artifacts useful regardless of what UI stack is ultimately chosen.

- Stand up `shared/contracts/` with JSON Schema (or OpenAPI) definitions for every Edge Function request/response and the `profiles`/`usage`/`voice_usage`/`task_runs` table shapes.
- Build the `quicktype`-based codegen script (`shared/codegen/`) that emits both Swift and C# types from those contracts, and verify the generated Swift types are drop-in-compatible with the hand-written structs already in `Mira/Services/*.swift` (a correctness check on the contracts themselves, with zero risk to the shipping macOS app since nothing is wired up yet).
- Resolve open items 1–2 above.

**Exit criteria:** a reviewed set of contracts + generated C# types that the user has looked at, with no app code written yet.

### Phase 2 — Windows project scaffolding + auth/entitlements only

The safest first *runnable* milestone, because it's pure networking against an already-hardened, already-live backend — no platform-specific capture/actuation/audio work, no UI-shell design decisions yet.

- Create the `windows/` solution (WinUI3, pending the user's confirmation of tech direction from WINDOWS_ARCHITECTURE.md §5).
- Implement Supabase email/password sign-in + session persistence (DPAPI-backed, per SECURITY_AND_PRIVACY.md §4's recommendation to improve on the macOS `UserDefaults` approach) + JWT auto-refresh, mirroring `SupabaseService.swift`'s design.
- Implement the Windows device-fingerprint equivalent and wire it to the existing `check-device`/`register-device` functions unchanged.
- Implement `EntitlementService`-equivalent plan caching against `profiles.plan`.
- A bare window (system tray icon + a simple settings/sign-in dialog) — deliberately *not* the notch/island UI yet.

**Exit criteria:** a Windows user can sign in, see their plan, and the device-lock/entitlement backend treats them correctly — verified against the real Supabase project, with the user reviewing before proceeding.

### Phase 3 — Minimal chat surface

- A simple chat window (not the notch/island shell) that routes prompts through `RouterService`'s reimplemented keyword-classifier + Haiku-gate logic, calling `anthropic-proxy`/`openai-proxy` with the JWT from Phase 2.
- Reimplement `MemoryStore` and `ProjectEngine`'s design faithfully (both confirmed pure-logic, local-JSON, no macOS dependency beyond the file-path convention) since they're needed for any chat context to feel like "Mira" rather than a bare LLM client.

**Exit criteria:** a working, unglamorous chat client that proves the shared backend, routing logic, and local-storage design all function correctly on Windows — the foundation everything else builds on.

### Phase 4 — Voice

- WASAPI capture/playback (NAudio or direct COM interop) replacing `AVAudioEngine`.
- Port the OpenAI Realtime WebSocket protocol layer from `RealtimeVoiceService.swift` near-verbatim (it's already portable JSON-over-WebSocket logic).
- Defer wake-word (Phase 0's evidence flags this as the largest genuine technology gap — needs its own design spike, not a port) to a later phase or a separate decision point.

### Phase 5 — Screen awareness + computer control

- Windows.Graphics.Capture for screenshots (replacing ScreenCaptureKit).
- UI Automation for element grounding and background actuation (replacing `AXUIElement`).
- `SendInput` for synthetic input (replacing `CGEvent`).
- This is the largest, riskiest phase — recommend it be its own dedicated planning pass (a "Phase 5 audit," structured like this Phase 0 but scoped to the actuation/permission-model design) before implementation, given the trust-model implications flagged in SECURITY_AND_PRIVACY.md §5.

### Phase 6 — Shell UI (island equivalent), agent chips, cursor companion

- Deliberately last among the major features, not first, despite being the most visually distinctive part of Mira — because it has zero backend dependency and can be designed/iterated on Windows-native terms once Phases 1–3 prove the underlying plumbing, rather than needing to match a macOS-specific "notch" metaphor that doesn't exist on Windows.

### Phase 7 — Updates & distribution

- Design a Windows updater (Squirrel.Windows or MSIX-based) against the same Supabase Storage bucket used today, plus an Authenticode signing pipeline — deliberately sequenced late since it only matters once there's a build worth distributing.

---

## Recommended safest first milestone

**Phase 2 (auth + entitlements + a bare tray-icon shell) is the safest place to start writing Windows code**, for three reasons confirmed by this audit:

1. It touches only the layer already confirmed to be client-agnostic (Supabase auth, `profiles`/`usage` schema, JWT-based Edge Functions) — there is no risk of needing to redesign the backend later based on something learned during this phase.
2. It has no platform-permission surface to design (no Accessibility-equivalent consent flow, no screen-capture picker, no microphone) — the security questions in SECURITY_AND_PRIVACY.md §5 don't need to be resolved yet to build it.
3. It produces something genuinely testable end-to-end against the real backend (sign in, see a plan, hit a real quota) without requiring any of the harder platform-integration decisions (UI shell design, wake-word technology choice, actuation permission model) to be made first.

This plan is a proposal. The next action is the user's review of all five Phase 0 documents — no Phase 1 work begins until that review happens and the user gives explicit direction on tech-stack confirmation, repository layout, and which open items from §"Phase 0" above should be resolved first.
