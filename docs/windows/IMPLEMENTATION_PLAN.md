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

**Open items from this audit, status as of 2026-07-18** (see WINDOWS_ARCHITECTURE.md §7 and SECURITY_AND_PRIVACY.md §1):
1. ~~Confirm whether Anthropic's `claude` CLI and OpenAI's `codex` CLI have Windows-native builds.~~ **Resolved** — both do. `codex` on Windows has a materially weaker sandbox than macOS/Linux per OpenAI's own docs, and Mira's current `CodexComputerUseService.swift` invocation uses the bypass-sandbox flag — this specific decision (whether to carry that flag into the Windows build) should be revisited in Phase 5, not assumed.
2. Confirm via `strings` on a built macOS binary whether any provider secret still ships client-side today. **Still open** — `Mira/Config/AppSecrets.swift` isn't just gitignored, its whole directory is absent from this checkout, so it can't be inspected from here at all; needs to happen on the Mac or wherever the file is populated.
3. Rotate the committed `CRON_SECRET` (independent of Windows work, should happen regardless of what the user decides about the port). **Still open** — this machine has no Supabase CLI installed and no active Supabase login, and the available Supabase MCP tools don't include a secrets-management call, so this needs to be done directly by someone with Supabase project access (CLI or dashboard).
4. A follow-up read of `WebsiteBuilderAgent`/`ResearchAgent`/`ContentAgent`/`PublishingAgent`/`WebsiteHealthAgent` (referenced but not opened in this audit) to determine whether that logic belongs in the shared Node sidecar rather than being reimplemented per-client. **Still open.**

---

## Proposed phase sequence (for discussion, not commitment)

### Phase 1 — Shared contracts + backend verification (no UI)

The lowest-risk, highest-leverage next step, because it touches only the already-shared backend layer and produces artifacts useful regardless of what UI stack is ultimately chosen.

**Status: contracts + codegen scaffolding done (2026-07-18).** `shared/contracts/` now has a JSON Schema for every client-facing Edge Function (`anthropic-proxy`, `openai-proxy`, `assemblyai-proxy`, `composio-proxy`, `mint-realtime-token`, `mint-assemblyai-token`, `openai-tts-proxy`, `openai-tts-narration`, `report-voice-usage`, `check-device`, `register-device`, `spotify-config`, `spotify-search`, `stripe-checkout`, `stripe-portal`, `skills-catalog`, `skills-publish`), the Supabase GoTrue auth response/request shapes, and the `profiles` table row — each derived by directly reading the corresponding source file, not guessed. `shared/codegen/` runs quicktype against those contracts and emits both Swift and C# types (`shared/codegen/generated/{swift,csharp}/`); this was actually run, not just written — including finding and fixing two real quicktype quirks (a schema shape that crashes the generator, and cross-file type-name collisions once multiple contracts' output shares one namespace) documented in `shared/codegen/README.md`. The generated `SupabaseAuthResponse`/`SupabaseAuthUser` Swift types were spot-checked field-for-field against the hand-written structs in `Mira/Services/SupabaseService.swift` and match.

**Not done / explicitly deferred, even though the contracts exist:**
- `usage`/`voice_usage`/`task_runs` table schemas — only `profiles` (the one table a client reads directly) is modeled; the others are written only by service-role Edge Functions and never read directly by a client, so they weren't prioritized. Add them if a future feature needs to read them directly.
- Wiring the generated Swift types into `Mira/Services/*.swift` to replace the hand-written structs — deliberately not done as part of standing up the pipeline; that's its own reviewed, call-site-by-call-site change against the live macOS app, per `shared/codegen/README.md`'s own integration note.
- A Windows C# project to consume `generated/csharp/` — doesn't exist yet (that's Phase 2).
- CI wiring for `npm run check` (the regenerate-and-diff drift check) — the script exists and works locally; nothing runs it automatically yet.
- Resolve open items 1–2 above (Windows CLI availability is resolved; `AppSecrets.swift` contents and the CRON_SECRET rotation are unrelated to this contracts work and remain open).

**Exit criteria:** a reviewed set of contracts + generated Swift/C# types — met. No app code (Mira/ or a Windows project) has been written.

### Phase 2 — Windows project scaffolding + auth/entitlements only

The safest first *runnable* milestone, because it's pure networking against an already-hardened, already-live backend — no platform-specific capture/actuation/audio work, no UI-shell design decisions yet.

**Status: done (2026-07-18), with one item deliberately left incomplete.** `windows/Mira.Windows.sln` exists with three projects: `Mira.Windows.Core` (business logic), `Mira.Windows.App` (WPF shell), `Mira.Windows.Core.Tests` (xunit, 30 tests, all passing). WPF was chosen over WinUI 3 — see WINDOWS_ARCHITECTURE.md §5 for why that changed from this doc's original framing.

- ✅ `Auth/SupabaseService.cs` — email/password sign-in + sign-up, JWT auto-refresh (proactive + reactive-after-401, single-flighted), session persisted via `Storage/DpapiFileStore.cs` (DPAPI-encrypted, not plaintext — a deliberate improvement over the macOS `UserDefaults` approach, confirmed in `Storage/DpapiFileStoreTests.cs`'s "not plaintext on disk" test). Uses the generated `Mira.Contracts.SessionResponse`/`SignInRequest`/`SignUpRequest` types directly rather than hand-rolled duplicates.
- ✅ `Device/DeviceFingerprintService.cs` — SHA-256(registry `MachineGuid` + DPAPI-persisted random GUID), same `"mira-v1:"`-prefixed shape as the macOS hash; wired to `check-device`/`register-device` via `Account/AccountService.cs` with **zero backend changes** (confirmed: the server treats the hash as an opaque string).
- ✅ `Entitlements/EntitlementService.cs` — plan cache (client-side, UX-only, exactly like the Swift original), `Can()` gating logic unit-tested against the confirmed Swift source values. Reuses the **generated** `ProfilePlan` enum from `shared/contracts/tables/profile-row.schema.json` rather than declaring a second, parallel plan enum.
- ✅ A bare window: `Mira.Windows.App` starts as a tray icon only (`TrayIconManager.cs`, via `NotifyIcon`/WinForms interop — WPF has no native tray control), opens a sign-in/status window on demand. Confirmed to actually launch and render (window title "Mira", responsive) via a local smoke test — not just "it compiles."
- ⚠️ **`Config/MiraConfig.cs`'s `SupabaseAnonKey` is a placeholder empty string, not filled in.** The anon key is safe to embed (public by design, see SECURITY_AND_PRIVACY.md §7) but this audit's checkout never contained the gitignored `Mira/Config/AppSecrets.swift` that holds the real value on the macOS side, so it couldn't be copied from there. **This must be filled in before the app can actually reach Supabase** — get the value from the Supabase project dashboard (Settings → API → anon/public key) or from `AppSecrets.swift` directly on a machine that has it.

**Explicitly not tested end-to-end:** no live sign-in/sign-up was performed against the real Supabase project. Creating an account or entering a password to authenticate isn't something this assistant will do on your behalf even for testing purposes — that verification is yours to run once the anon key above is filled in. Everything short of that (build, unit tests, app launch, DPAPI round-trip, JSON contract shapes) was actually run, not just written.

**Exit criteria:** a Windows user can sign in, see their plan, and the device-lock/entitlement backend treats them correctly — code and local testing done; the live "actually sign in against production" verification is pending the anon key + the user's own pass.

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
