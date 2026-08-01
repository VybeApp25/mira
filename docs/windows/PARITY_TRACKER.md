# Mira — Mac ↔ Windows Parity Tracker

One brain, two bodies. The backend is shared and identical; the macOS client is shipped and paid-live; the Windows client (`feat/windows-mira`) is a real, in-progress rewrite in C#/WinUI3 — no SwiftUI carries over. Every row below is scored against this branch's own evidence-backed [`FEATURE_PARITY_MATRIX.md`](FEATURE_PARITY_MATRIX.md), cross-checked against the actual Windows source tree.

- **Scored:** 2026-07-20
- **Mac:** `main` — v1.0.2 (build 5), live
- **Windows:** `feat/windows-mira` (PR #38)

---

## Headline — three buckets

| Bucket | Complete | Meaning |
|---|---|---|
| **Both** — shared backend / infra | **100%** | Supabase auth, secrets proxy, Stripe, per-plan quotas, model-routing proxy, Node sidecar, community-skills API. Built once, serves both. New shared type-codegen layer just added. |
| **Mac** — native client | **100%** | The reference baseline. 140 services, 56 views, shipped and paid-live. Every Windows row is measured against this. |
| **Windows** — native client | **57% code-present** · **~0% runtime-verified** | 12 Done / 16 Partial / 7 Missing / 1 N/A across the 36 audited features. The branch has not been built or driven, so this is "written," not "working." |

### How the 57% is computed (a true, defensible number)

Each of the 36 audited features scores **Done = 1.0**, **Partial = 0.5**, **Missing = 0**. One feature (custom Dock / OS toggles) is **N/A** — no Windows equivalent exists as a matter of platform architecture — so it is removed from the denominator:

```
(12 × 1.0 + 16 × 0.5) / 35  =  20 / 35  =  57%
```

This measures **feature breadth with code present in the branch** — not lines of code, not effort, and **not** whether it runs. Verified-working parity is a separate, lower number that stays at ~0% until the Windows app is built and driven.

---

## Feature matrix — 36 rows

Legend: ✅ Done · 🟡 Partial · 🔴 Missing · ⚪ N/A (no OS equivalent). **Layer** — `shared` means the backend does the work for both clients.

### Core assistant loop

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 4 | Voice / real-time convo | shared proto | ✅ | ✅ | Full C# stack — 827-line `RealtimeVoiceService`, WASAPI mic/playback. Protocol ports near-verbatim. |
| 29 | Model routing | algorithm | ✅ | ✅ | `RouterService` (642 lines) + tests. Same two-tier classifier→Haiku-gate taxonomy. |
| 15 | Memories | local JSON | ✅ | ✅ | `MemoryStore` + decay model ported near-drop-in. Local-only, no network. |
| 17 | Skills — Teaching / Learn-Along | bundles | ✅ | ✅ | Full `Learn/` dir + tests. Only `darkModeEnabled` check needs a Windows registry swap. |
| 16 | Projects (sessions/checkpoints) | local JSON | ✅ | 🔴 | No `Projects/` dir on Windows yet. Pure-logic port — "closest thing to drop-in" per audit, just unwritten. |

### Screen awareness & computer control

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 6 | Screen capture | native | ✅ | 🟡 | `ScreenCapture.cs` present (Windows.Graphics.Capture). Vision-call plumbing reuses. |
| 7 | Element grounding | native | ✅ | 🟡 | `GuidanceLocator.cs` — UI Automation stand-in for AXUIElement. Algorithm ports, primitives don't. |
| 8 | Background actuation | native | ✅ | 🟡 | Orchestrator routes; UIAutomation coverage across legacy Win32/Electron apps is inconsistent. |
| 9 | Synthetic input | native | ✅ | ✅ | `SyntheticInput.cs` (227 lines, SendInput + VK table). Orchestration loop ported (328 lines). |
| 10 | Codex-CLI computer control | subprocess | ✅ | 🔴 | No Codex bridge on Windows. CLI exists but the `--dangerously-bypass-sandbox` flag needs its own review first. |
| 30 | Claude Code / Codex bridge | subprocess | ✅ | 🔴 | Both CLIs ship native Windows builds; not wired. Mac hardcodes a dev home path — don't copy that. |

### Interface & interaction shell

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 1 | Island / expanded interface | UI shell | ✅ | 🟡 | `IslandWindow`/`MainWindow` scaffolded (WinUI3). No "notch" on Windows — needs a native visual design. |
| 3 | Agent chips (floating) | UI shell | ✅ | 🟡 | `AgentActivityWindow` + `ClickThrough` + `CaptureAffinity` present; job/activity model ports. |
| 11 | Cursor bubbles / companion | UI shell | ✅ | 🟡 | `OverlayWindow` + `ChatBubble` + `PointToCanvas`. `GetCursorPos` polling mirrors Mac's approach. |
| 5 | Wake phrase ("hey mira") | native | ✅ | 🟡 | `WakeWordService` shell + bridge exist, but the engine (Porcupine/openWakeWord/whisper) is the single biggest tech gap. |
| 35 | Global shortcuts | native | ✅ | ✅ | `GlobalHotkey.cs` (RegisterHotKey). Press/release PTT semantics to confirm. |
| 12 | System notifications | native | ✅ | 🟡 | `TrayIconManager` present; App-SDK AppNotifications shim is thin, not confirmed wired. |
| 13 | In-app toast | UI | ✅ | 🟡 | UI-layer only; trivial logic. Rebuild in WinUI3. |
| 2 | Custom Dock / OS toggles | native | ✅ | ⚪ | Taskbar can't be shell-hidden like the Dock. Architecturally impossible — descope, don't backlog. |

### Autonomy & background work

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 23 | Node sidecar / Composio | shared | ✅ | 🟡 | Sidecar is portable JS (reuse fully); Windows node-discovery + orphan-reaping launcher to finish. |
| 24 | In-process agent runners | logic | ✅ | 🟡 | `ContentAgent` / `DeepResearchAgent` / `GenericAgent` stubbed. `WebsiteBuilderAgent` not yet ported. |
| 25 | Scheduler / cron / triggers | logic | ✅ | 🟡 | `Crons/` full (scheduler+store+tests). Missing: file-watch (ReadDirectoryChangesW) + webhook listener. |
| 14 | Daily briefing | mixed | ✅ | 🟡 | LiveLookup weather ported; calendar needs Graph API (no EventKit). Mac reachability itself unconfirmed. |

### Skills & extensibility

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 20 | Community skills (browse/publish) | shared | ✅ | ✅ | Backend reused as-is; Skills catalog + HttpClient client present. |
| 18 | Prompt-injection skills | format | ✅ | 🟡 | Skill store/parser/loader present. AppleScript-only skills (Notes/Reminders/iMessage) have no Windows path. |
| 19 | Python skill runner | native | ✅ | 🔴 | No Windows venv runner yet. Needs `Scripts\python.exe` + PowerShell quoting; some skills lose parity. |

### Data, storage & content

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 31 | Local storage (JSON) | native | ✅ | ✅ | `LocalAppData` under `%LOCALAPPDATA%\Mira`, same schemas. |
| 32 | Settings store (UserDefaults) | native | ✅ | ✅ | Settings classes throughout (Appearance/Personality/Voice/etc.). Low risk. |
| 33 | Secure storage (Keychain) | native | ✅ | ✅ | `DpapiFileStore` + `SecureSessionStore` + tests. DPAPI replaces Keychain. |
| 21 | Saved content / output store | native | ✅ | 🔴 | No registry/versioning store yet. `System.IO.Compression` replaces `NSFileCoordinator`. |
| 22 | File shelf | native | ✅ | 🟡 | `FileShelfStore` (129 lines) + tests. AirDrop share has no Windows equivalent. |

### Accounts, billing & infrastructure

| # | Feature | Layer | Mac | Win | Notes / gap |
|---|---|---|---|---|---|
| 26 | Authentication | shared | ✅ | ✅ | Supabase + Account + SecureSession + device fingerprint (WMI UUID) + tests. Apple sign-in is Mac-only. |
| 28 | Secrets / provider proxy | shared | ✅ | ✅ | `AnthropicProxyClient` + `OpenAIProxyClient`, JWT header pattern. This is the whole point of the design. |
| 27 | Subscriptions (Stripe) | shared | ✅ | 🟡 | Entitlements + plan gating present; open Checkout/Portal via default browser to confirm end-to-end. |
| 34 | Updates & distribution | native | ✅ | 🔴 | No updater/signing pipeline. Needs Squirrel/MSIX + Authenticode (different trust model than notarization). |
| 36 | Telemetry (PostHog) | shared api | ✅ | 🔴 | No .NET PostHog client wired. Low effort — official cross-platform HTTP API. |

---

## What closing the gap to 100% actually requires

### 🔴 Missing — 7 net-new builds

1. **Wake-word engine** — biggest single tech gap; pick Porcupine / openWakeWord / whisper.cpp.
2. **Updater + signing** — Squirrel/MSIX + Authenticode pipeline.
3. **Projects** — pure-logic port, no excuse, just unwritten.
4. **Python skill runner** — Windows venv + PowerShell invocation.
5. **Saved-content store** — registry + zip export.
6. **Codex / Claude-Code bridges** — wire native Windows CLIs (review the sandbox flag).
7. **Telemetry client** — thin PostHog HTTP shim.

### 🟡 Partial — 16 to finish + verify

- **Build & run the branch first** — nothing here is runtime-verified; that is the true 0→1.
- **Screen capture / grounding / actuation** — coverage testing across real Win32 + Electron apps.
- **UI shell** (island, chips, cursor, toasts) — native visual design, no notch metaphor.
- **Sidecar launcher, scheduler transports** (file-watch, webhook), calendar via Graph.
- **Adopt the shared codegen** so Swift + C# models can't drift — the one fix that improves *both*.

---

## The lever that raises Mac, Windows, and Both at once

The new `shared/contracts` + `shared/codegen` layer generates Swift **and** C# types from one JSON source of truth. Adopt it everywhere and a backend change updates both clients from one place — the only sustainable way to run two native apps without doubling the bug surface.

Separately, rotate the `CRON_SECRET` that [`SECURITY_AND_PRIVACY.md`](SECURITY_AND_PRIVACY.md) flagged as committed in plaintext — that's shared infra, so it protects both.

---

*Scored from the `feat/windows-mira` source inventory + the branch's `FEATURE_PARITY_MATRIX.md`. Code-present breadth, not runtime-verified. Mira internal.*
