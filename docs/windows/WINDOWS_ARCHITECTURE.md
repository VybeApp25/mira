# Windows Architecture — Phase 0 Design Direction

This document proposes a target architecture for a native Windows Mira, grounded in the evidence in [REPOSITORY_EVIDENCE.md](REPOSITORY_EVIDENCE.md) and the feature-by-feature breakdown in [FEATURE_PARITY_MATRIX.md](FEATURE_PARITY_MATRIX.md). It is a **design proposal for review**, not an implementation — no macOS code is touched by this phase, and no Windows code is written yet.

---

## 1. What the current system actually is

Reading the source confirms Mira is not one monolith but four layers with very different portability profiles:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. macOS UI shell (SwiftUI + AppKit)                         │  ~150 Swift files, Views/ + Managers/ + Controllers/
│    Island/notch, chips, cursor bubbles, dock, HUDs           │  100% macOS-specific — NSPanel, NSScreen notch APIs,
│                                                                │  Carbon hotkeys, NSVisualEffectView, EventKit UI
├─────────────────────────────────────────────────────────────┤
│ 2. macOS platform services (Swift, Services/)                │  AVFoundation, Speech, ScreenCaptureKit, AXUIElement,
│    Voice capture, wake word, screen capture, actuation,       │  CGEvent/CGEventTap, CoreAudio, Keychain, AppleScript
│    hotkeys, dock manipulation, calendar/weather                │  — each has a Windows analog, none port directly
├─────────────────────────────────────────────────────────────┤
│ 3. Portable business logic (Swift, mostly Services/+Models/) │  RouterService, ProjectEngine, MemoryStore, AgentJobStore,
│    Routing, memories, projects, entitlements, JSON stores      │  EntitlementService, SkillStore — pure Swift/Foundation,
│                                                                │  no AppKit — confirmed by direct reading, not by name
├─────────────────────────────────────────────────────────────┤
│ 4. Backend (shared, already cross-platform)                   │  Supabase Postgres + Edge Functions (Deno/TS),
│    Auth, entitlements, billing, secrets proxy, AgentService    │  Node.js AgentService sidecar (Express) — confirmed
│    Node sidecar                                                │  zero macOS-specific code in this layer
└─────────────────────────────────────────────────────────────┘
```

Layer 4 is the single most important finding of this audit: **the backend was already built to be client-agnostic.** `MiraBackend.useProxy = true` is live in the current source, `supabase/functions/_shared/auth.ts` authenticates by verified JWT (never client-asserted identity), and the Node sidecar (`AgentService/src/*.ts`) was grepped for shell-outs and platform branches with zero hits. None of that layer needs to change for a Windows client to use it.

Layers 1–3 are Swift, and Swift's Windows story (SwiftPM + swift-corelibs-Foundation on Windows) is real but young and not something this app currently exercises or depends on. **This audit does not recommend attempting to run the existing Swift UI/service code on Windows.** The business logic in layer 3 is valuable as a *design reference* (the exact confidence-decay formula in `MemoryStore`, the exact quota semantics in `ProjectEngine`, the exact routing taxonomy in `RouterService`) to reimplement faithfully in whatever the Windows-native stack turns out to be — not as code to compile unchanged.

---

## 2. What can be shared as-is

| Component | Why it's shareable | Action needed |
|---|---|---|
| Supabase Postgres schema + RLS policies | Confirmed provider-agnostic SQL; `profiles`/`usage`/`voice_usage`/`task_runs`/`community_skills` tables have no macOS concept baked in | None — Windows client reads/writes the same tables through the same REST/RPC surface |
| Supabase Edge Functions (`anthropic-proxy`, `openai-proxy`, `assemblyai-proxy`, `composio-proxy`, `mint-realtime-token`, `mint-assemblyai-token`, `stripe-*`, `skills-*`, `check-device`, `register-device`, `spend-alarm`) | Deno/TypeScript, JWT-authenticated, zero client-platform awareness in the code read | None for most; `check-device`/`register-device`'s device-hash *scheme* needs a Windows-equivalent hash computed client-side (see §5) |
| `AgentService/src/*.ts` (Node sidecar) | Confirmed zero shell-outs, zero `process.platform` branching, builds to a portable bundled `server.js` via esbuild | None to the sidecar itself — only its **launcher** changes (see §3) |
| Business-logic *design* (not code): routing taxonomy, memory confidence model, project session/checkpoint model, entitlement plan matrix, skill bundle format | Confirmed pure Swift/Foundation with no AppKit dependency, but Swift-on-Windows is not the recommended target | Reimplement faithfully in the chosen Windows-native language — treat the Swift source as the spec |
| Sparkle-hosted release artifacts location (Supabase Storage bucket) | Just cloud storage; not Sparkle-specific | Reuse the bucket for Windows installers/update packages under a separate path/appcast-equivalent feed |

## 3. What is macOS-specific and needs a full rewrite

Confirmed from the evidence ledger — no Windows equivalent exists in the same shape:

- **The entire UI shell**: SwiftUI has no Windows runtime. Every `Views/*.swift` file is a full rewrite in whatever UI framework is chosen.
- **Notch/island windowing**: derived from `NSScreen.safeAreaInsets`/`auxiliaryTopLeftArea` — hardware-notch-specific APIs with literally no Windows concept to hook into. This needs a new visual metaphor, not a port (e.g., a small persistent flyout anchored to a screen edge or the system tray, not a fake camera-notch shape).
- **Wake word**: on-device `SFSpeechRecognizer`, continuous ASR substring-matched against trigger phrases. No equivalent ships with Windows; needs a dedicated wake-word engine or local Whisper.cpp instance — a different technical approach, not a port.
- **Screen capture & actuation**: ScreenCaptureKit → Windows.Graphics.Capture/DXGI Desktop Duplication; `AXUIElement` → UI Automation; `CGEvent`/`CGEventTap` → `SendInput`/`SetWindowsHookEx`. Each pairing is conceptually parallel but is a different API family with a different permission model (Windows has no TCC-equivalent consent database for Accessibility/screen-recording; consent is far less centralized).
- **Global hotkeys**: Carbon HotKey Manager → Win32 `RegisterHotKey`/`WM_HOTKEY` or a low-level keyboard hook for press/release granularity.
- **AppleScript/Automation-driven features**: browser-URL reading, Spotify/Music/Reminders/Notes/Terminal automation, iMessage integration. These rely on Apple Events, which has no Windows analog at all — several of these (iMessage, Find My, AirDrop) simply have no Windows equivalent and should be named exclusions, not backlog items.
- **Sparkle auto-update, Developer-ID signing + notarization**: macOS-only update framework and Apple's specific trust chain. Windows needs a distinct updater (Squirrel.Windows or MSIX-based) and Authenticode signing — a different trust model, not a port of the existing pipeline.
- **Keychain, IOKit hardware serial**: `Security` framework and IOKit have no Windows equivalent; device fingerprinting and secret storage need DPAPI/Credential Manager and a WMI-based hardware identifier.
- **`NSBackgroundActivityScheduler`, `Network.framework` (`NWListener`), kqueue-based file watching (`DispatchSourceFileSystemObject`/`O_EVTONLY`)**: each needs a distinct Windows primitive (Task Scheduler or an in-process timer; a `TcpListener`/Kestrel-based webhook listener; `ReadDirectoryChangesW`).

---

## 4. Should the Windows app live in this monorepo?

**Yes, with a clear boundary.** The backend (Supabase functions/migrations, AgentService sidecar) is already the shared substrate both clients will hit — keeping it in one repo means schema changes, quota logic, and proxy contracts stay in lockstep for both platforms instead of drifting across two repos. The cost of a monorepo (accidental coupling, one platform's build breaking the other's CI) is manageable as long as the boundary is enforced structurally, not just by convention.

Recommended layout:

```
mira/
├── Mira/                    # untouched — existing macOS app
├── Mira.xcodeproj/          # untouched
├── AgentService/            # shared — Node sidecar, used by BOTH clients
├── supabase/                # shared — Postgres schema + Edge Functions, used by BOTH clients
├── docs/
│   ├── architecture/        # existing macOS/general architecture docs
│   └── windows/             # this Phase 0 audit + ongoing Windows planning docs
├── shared/                  # NEW — platform-agnostic contracts (see §5)
│   ├── contracts/           # JSON Schema / OpenAPI definitions for every edge-function request/response
│   └── codegen/             # scripts that generate Swift + C# types from shared/contracts
└── windows/                 # NEW — the Windows app, once Phase 1+ begins
    ├── Mira.Windows.sln
    ├── Mira.Windows.App/     # WinUI3/WPF project
    └── Mira.Windows.Core/    # platform-agnostic C# business logic (routing, memory model, entitlements)
```

Do **not** touch `Mira/`, `Mira.xcodeproj/`, or existing `docs/architecture/` content — this audit and any Phase 1 work add files, they don't move or edit the macOS app.

---

## 5. Windows technology direction

**Recommendation: C# / .NET 8+ with WinUI 3** for the app shell, given the user's own framing of the question ("how C# and Swift types should be generated") assumes C# as the target. Rationale:
- WinUI 3 is Microsoft's current native Windows UI framework with Mica/Acrylic backdrop support — the closest analog to the `NSVisualEffectView`/Liquid-Glass materials used throughout the macOS chip/panel UI.
- .NET has first-class support for everything the shared backend needs: `HttpClient`/`ClientWebSocket` for Supabase/provider calls, `System.Diagnostics.Process` for launching the Node sidecar, DPAPI/`Windows.Security.Credentials.PasswordVault` for secret storage, UI Automation via `System.Windows.Automation` or the newer WinRT UIA COM interop, `Microsoft.Windows.AppNotifications` for toasts.
- WPF is a credible fallback if WinUI 3's packaging/deployment model (MSIX-first) proves friction for a Sparkle-style direct-download distribution — flag this as a decision to revisit once the update/distribution mechanism (§ Feature 34) is designed, not before.

This is a **direction recommendation for Phase 1 discussion**, not a locked decision — the user should confirm before any project scaffolding is created.

### Type/schema generation — avoiding hand-duplicated Swift/C# types

The risk: today, every Supabase Edge Function's request/response shape and every Postgres table schema is implicitly defined twice — once in the Deno function body, once in the Swift `Codable` structs that call it (`AuthResponse`, `SupabaseSession`, the various `Row`/response structs seen throughout `Mira/Services/*.swift`). Adding a third, hand-written C# copy would triple the maintenance surface and guarantee drift.

**Recommended approach — a single JSON Schema (or OpenAPI) source of truth, with generated clients on both sides:**

1. **Define contracts once, in `shared/contracts/`.** For each Edge Function and each Postgres table exposed via PostgREST, write a JSON Schema (or a light OpenAPI 3.1 document covering all the edge functions as paths). This is new work — none of this exists today; the contracts currently live only implicitly in the Deno function bodies and the `_shared/auth.ts` response shapes.
2. **Generate Swift types** from that schema using `quicktype` (supports Swift `Codable` output) or a schema-specific generator, and check the generated file into `Mira/Services/Generated/` — replacing the hand-written `Codable` structs currently scattered across `SupabaseService.swift`, `ClaudeService.swift`, etc., one call site at a time (non-disruptive to the existing macOS app since the generated types can be made to match the existing shapes).
3. **Generate C# types** from the same schema using `quicktype`'s C# target (or `NJsonSchema`/`NSwag` if an OpenAPI document is chosen instead of raw JSON Schema — NSwag additionally generates a typed `HttpClient` wrapper, which removes a whole class of hand-written request-building code on the Windows side).
4. **Regenerate via a checked-in script** (`shared/codegen/generate.sh` or a `dotnet tool`), run manually for now and wired into CI once both clients depend on it, so a schema change can never silently drift between platforms.
5. **Supabase's own `generate_typescript_types` tooling** already exists for the Postgres schema → TypeScript (used implicitly by the Deno functions today); treat that TypeScript output as an *additional* input to the JSON-Schema-authoring step in (1), not a replacement for it, since the edge-function request/response bodies are hand-shaped JSON, not raw table rows.

This is scoped as its own early Phase 1 workstream (see [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)) — it has to exist before meaningful Windows-client networking code is written, otherwise the C# types will be hand-copied from reading Swift source (exactly the duplication this is meant to avoid).

---

## 6. Secrets and privileged credentials — what must stay server-side

Full detail in [SECURITY_AND_PRIVACY.md](SECURITY_AND_PRIVACY.md); the headline architectural constraint for this doc:

- **No provider API key (Anthropic, OpenAI, AssemblyAI, Composio, Stripe secret key, Miso) may ever be embedded in the Windows client**, mirroring the macOS app's already-live `MiraBackend.useProxy = true` design. The Windows client authenticates to Supabase Edge Functions with the user's JWT, exactly like the Mac client — this is a direct behavioral port, not a new design.
- The **Supabase service-role key** and **Stripe webhook secret** live only in Edge Function environment variables (`Deno.env.get(...)`, confirmed in `_shared/auth.ts` and `stripe-webhook/index.ts`) and must never be referenced from any client code, Windows or Mac.
- The **device-fingerprint scheme** (SHA-256 of a hardware serial + a persisted random UUID) needs a Windows-native equivalent (WMI `Win32_ComputerSystemProduct.UUID` + DPAPI-protected UUID) that produces a hash in the same *shape* the `check-device`/`register-device` functions expect, so the one-free-account-per-device enforcement continues to work without a schema change.

---

## 7. Open questions this audit could not resolve from source

- Whether Anthropic's `claude` CLI or OpenAI's `codex` CLI ship Windows-native builds. If not, the Codex/Claude-Code-as-subprocess pattern (features 10 and 30 in the parity matrix) needs a different design for Windows — possibly calling the same underlying APIs directly instead of shelling out to a CLI.
- The actual current contents of `Mira/Config/AppSecrets.swift` (gitignored, absent from this checkout) — needed to confirm whether any provider secret still ships in the macOS binary today, despite `useProxy = true`.
- Whether the in-process Swift agent runners (`WebsiteBuilderAgent` et al., referenced but not opened in this pass) contain logic that should move into the shared Node sidecar rather than being reimplemented a third time in C#.

These should be resolved (the first two by direct investigation, the third by a follow-up code read) before Phase 1 implementation scoping is finalized.
