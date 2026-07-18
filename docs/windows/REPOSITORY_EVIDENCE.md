# Repository Evidence Ledger — Mira macOS → Windows Phase 0

**Purpose.** This is the evidence backbone for the Windows-port planning docs in this folder. Every row cites an exact file path and symbol from this repository as it stood on **2026-07-18**, on branch `feat/windows-mira`, read directly (`Read`/`Grep`) or via a scoped research pass over the same files. Nothing here is inferred from the product description, README, or naming conventions alone — where a file's name doesn't match its contents, that mismatch is called out explicitly.

**Status legend**
- **Confirmed** — read directly, behavior verified from source.
- **Partial** — file read, but a dependent symbol/behavior it calls into was not itself opened, or the claim covers only part of the file.
- **Unknown** — not confirmed in inspected source. Stated explicitly rather than inferred.
- **macOS-tested** vs **Windows-tested**: this entire audit was produced on a Windows machine with no macOS runtime available. "Confirmed" below means *confirmed by reading source*, not *confirmed by running the app on a Mac*. Nothing in this ledger should be read as "verified working on macOS at runtime" — see the note at the end of each section.

Line numbers are pointers, not permanent anchors — they reflect the file state at audit time.

---

## 1. Island / expanded interface (notch UI)

| File | Symbol | Behavior (confirmed by reading source) | Status |
|---|---|---|---|
| `Mira/Managers/MiraIslandWindowManager.swift` | `IslandPanel: NSPanel`, `FirstMouseHostingView<Content>` | Single `NSPanel` (`styleMask: [.borderless, .nonactivatingPanel]`), `level = .statusBar + 10`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`. `setInteractive(_:)` toggles `ignoresMouseEvents` and calls `makeKey()` (not `makeKeyAndOrderFront`) so the panel never steals focus from the frontmost app. | Confirmed |
| `Mira/Managers/NotchGeometryProvider.swift` | `NotchGeometryProvider.detect(for:)`, `realNotch`, `virtualNotch` | Notch width/height derived from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` (macOS 12+ hardware-notch APIs). Non-notched screens get a synthesized 200×37pt "virtual notch." | Confirmed |
| `Mira/Views/MiraIslandView.swift` | `MiraIslandView`, `IslandShape: Shape, Animatable` | Pure SwiftUI; `IslandTab` enum drives `tabContent` switch (home/chat/shelf/camera/agents/learn/settings/crons/labs/skills). Opts out of the macOS menu-bar safe area via `.ignoresSafeArea()`. | Confirmed |
| `Mira/Managers/NotchManager.swift` | `NotchManager` | Orchestrates geometry → window manager → hover tracking → animation; owns `GlobalShortcutManager`, wires ~15 `NotificationCenter` observers. | Confirmed |
| `Mira/Controllers/NotchHUDController.swift` | — | **One-line stub**: `// Replaced by Managers/NotchManager.swift, MiraIslandWindowManager.swift, HoverTrackingManager.swift, and AnimationController.swift.` Contains no logic despite the file existing. | Confirmed (dead file) |
| `Mira/Views/NotchHUDView.swift` | — | **One-line stub**, superseded by `MiraIslandView.swift`. | Confirmed (dead file) |
| `Mira/Views/NotchHomeIdleView.swift` | `NotchHomeTabView` (not `NotchHomeIdleView`) | File does not define a type matching its filename; defines the Home-tab media/calendar panel actually used by `MiraIslandView`. Uses `EKEvent` directly. | Confirmed (name mismatch) |
| `Mira/Views/MiraPanel.swift` | `MiraPanel: View` | Despite living in `Views/` and being named "Panel," this is a plain SwiftUI `View`, not an `NSPanel`. No window-hosting code found in the file; no window manager in the inspected set instantiates it. Not confirmed dead code (no exhaustive project-wide reference search performed). | Partial |
| `Mira/Controllers/OverlayWindowController.swift` | `OverlayWindowController` | Full-screen borderless `NSWindow` (`level: .screenSaver`, click-through) hosting `PointerOverlay`/`GuidanceOverlayView`/`SharpieOverlayView` for computer-use annotation. | Confirmed |
| `Mira/Controllers/HUDOverlayWindowController.swift` | `HUDOverlayWindowController` | Floating volume/brightness HUD, mimics the stock macOS HUD via `NSPanel` + `NSHostingView(SystemHUDView)`. | Confirmed |
| `Mira/Managers/MiraDockManager.swift` | `MiraDockManager`, `hideNativeDock()` | Shells out via `Process`/`/bin/zsh` to run `defaults write com.apple.dock autohide -bool true` then `killall Dock` — **directly manipulates the real macOS Dock**. Builds its own custom-dock `NSPanel`. | Confirmed |
| `Mira/Views/MiraDockView.swift` | `MiraDockView`, `DockWidgetType` | Widget registry (clock/weather/nowPlaying/battery/appLauncher/pomodoro/toggles/soundMeter/systemStats). Shells out to `networksetup`, `defaults -currentHost write com.apple.notificationcenterui`, `blueutil`, `osascript` for Wi-Fi/DND/Bluetooth/Dark-Mode toggles. Uses macOS 26 `.glassEffect` with `.ultraThinMaterial` fallback. | Confirmed |
| `Mira/Views/BriefingView.swift` | `BriefingView` | Functionally complete (greeting, calendar, memories, battery) but a targeted search found no call site that renders it anywhere in the live UI graph. `mira_last_briefing` is written but never read. | Confirmed code exists; **reachability unknown** — flagged as likely-orphaned |
| `Mira/Managers/GlobalShortcutManager.swift` | `GlobalShortcutManager`, `miraHotKeyHandler` | Uses **Carbon** (`RegisterEventHotKey`/`InstallEventHandler`), not `CGEventTap` — explicitly to avoid requiring Accessibility permission. 5 hardcoded shortcuts (voice/text/draw/dictate/clipboard). | Confirmed |
| `Mira/Managers/HoverTrackingManager.swift` | `HoverTrackingManager` | Polls `NSEvent.mouseLocation` every 40ms via `Timer` (not an event tap/monitor) — explicitly to avoid Input Monitoring restrictions. Drives notch hover-to-expand. | Confirmed |

**Cross-cutting macOS APIs in this subsystem:** `NSPanel`/`NSWindow.Level`, `NSScreen.safeAreaInsets`/`auxiliaryTopLeftArea`, `NSVisualEffectView`, `NSHostingView`, Carbon HotKey Manager, `EventKit`, shell-outs to `defaults`/`killall`/`networksetup`/`blueutil`/`osascript`. None have a direct Windows equivalent; see [WINDOWS_ARCHITECTURE.md](WINDOWS_ARCHITECTURE.md).

---

## 2. Agent chips

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/ActionChipService.swift` | `ActionChipService` | Pure state/business logic (`@Published chips: [ProjectNextAction]`), caps to 3, auto-dismiss after 8s. No window code. | Confirmed |
| `Mira/Views/ActionChipsView.swift` | `ActionChipsView` | Embedded SwiftUI `HStack`, rendered inline inside the island's HUD overlay — not a separate floating window. | Confirmed |
| `Mira/Views/FloatingAgentChipView.swift` | `FloatingAgentChipView`, `NonHitTestingVisualEffectView: NSVisualEffectView` | Defines the "liquid glass" `NSVisualEffectView` (`.hudWindow` material, `.behindWindow` blending) bridged into SwiftUI. | Confirmed |
| `Mira/Managers/AgentHUDWindowManager.swift` (loaded as a dependency, not originally in scope) | `AgentHUDWindowManager` | One `NSPanel` per physical `NSScreen`, pinned to the right edge, `level = .statusBar + 5`, custom `NSView` hit-test pass-through so transparent regions click through. | Confirmed |
| `Mira/Views/AgentActivityChipView.swift` | `AgentActivityChipView` | Read-only, non-interactive chip variant for live `AgentActivity`. | Confirmed |
| `Mira/Models/AgentActivity.swift` | `AgentActivity`, `AgentActivityStatus` | In-memory-only value type; explicitly documented as separate from persisted `AgentJobStatus`/`AgentTask`. Nothing here touches disk. | Confirmed |

**Trigger mechanism:** chip visibility is driven by agent-job lifecycle events (`AgentJobStore`), not by any window-system event. Three distinct chip families exist (next-action suggestion chips = embedded SwiftUI; job/activity chips = truly floating `NSPanel`s).

---

## 3. Voice and real-time conversation

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/RealtimeVoiceService.swift` | `RealtimeVoiceService`, `captureEngine: AVAudioEngine`, `webSocket: URLSessionWebSocketTask` | Captures mic via `AVAudioEngine` tap, converts to 24kHz Int16 PCM, sends over `wss://api.openai.com/v1/realtime?model=gpt-realtime` via `URLSessionWebSocketTask`. Screen snapshots (via `ScreenCaptureService`) ride the same session as `input_image` content blocks. | Confirmed |
| — | raw-key fallback | Confirmed present, but at different lines than a prior reference (`:279`) suggested — current location is inside `openSocketAsync()` (~lines 389–423): in **direct mode** (`!MiraBackend.useProxy`) only, falls back to embedded `AppSecrets.openAIKey`; in **proxy mode**, a mint failure refuses to connect rather than leaking the key. `MiraBackend.useProxy` is `true` in the current source. | Confirmed (location differs from the prior citation; behavior itself confirmed) |
| `Mira/Services/VoiceService.swift` | `VoiceService` | Legacy/simpler path: `SFSpeechRecognizer` (Apple Speech framework) + `AVSpeechSynthesizer`. No network calls in this file at all — appears to be a smaller fallback, distinct from `RealtimeVoiceService`. | Confirmed |
| `Mira/Services/AssemblyAIService.swift` | `AssemblyAIService` | Pure HTTP REST client (`/v2/upload`, `/v2/transcript`) via `MiraBackend.proxyData`. No Apple-only APIs — fully portable. | Confirmed |
| `Mira/Services/AssemblyAIStreamingService.swift` | `AssemblyAIStreamingService` | WebSocket to `wss://streaming.assemblyai.com/v3/ws`; raw binary frames (not JSON/base64), distinct from RealtimeVoiceService's framing. Second, separate raw-key-fallback path exists, same proxy-gated pattern. | Confirmed |
| `Mira/Services/LiveTranscriptionStream.swift` | `LiveTranscriptionStream` | Generalized AssemblyAI v3 stream; accepts `AVAudioPCMBuffer` from any source — used with two simultaneous instances (mic + system audio) for call-transcription "speaker separation without ML diarization." | Confirmed |
| `Mira/Services/MisoTTSService.swift` | `MisoTTSService` | Plain HTTPS POST to `api.misolabs.ai/v1/tts`, bring-your-own-key (no secret ships in the binary). Playback via `AVAudioPlayer`. | Confirmed |
| `Mira/Services/AudioCueService.swift` | `AudioCueService` | Bundled UI sound effects via `AVAudioPlayer`, falling back to `NSSound` (AppKit-only, no Windows equivalent). | Confirmed |
| `Mira/Services/MicLevelMonitor.swift` | `MicLevelMonitor` | Mic RMS metering via `AVAudioEngine` tap; device selection via raw **CoreAudio HAL** (`AudioObjectGetPropertyData`) — no Windows analogue (would map to WASAPI/MMDevice). | Confirmed |
| `Mira/Services/AudioOutputRoute.swift` | `AudioOutputRoute` | 100% CoreAudio HAL (`kAudioDevicePropertyTransportType`) — detects built-in-speaker vs. external output to gate voice barge-in. | Confirmed |
| `Mira/Services/VoicePreviewService.swift` | `VoicePreviewService` | OpenAI TTS (`gpt-4o-mini-tts`) via `MiraBackend.openAITTSURL`, cached to temp dir, played via `AVAudioPlayer`. | Confirmed |

**Cross-cutting:** `AVAudioEngine`/`AVAudioConverter`/`AVAudioPlayerNode`/`AVAudioPCMBuffer` (AVFoundation) appear throughout and are Apple-only. The **network/provider layer** (OpenAI Realtime WebSocket, AssemblyAI REST/WebSocket, Anthropic Messages API) is plain `URLSession`/`URLSessionWebSocketTask` and is portable in principle (would map to `ClientWebSocket`/`HttpClient` on .NET). `NSAppleScript` is used to duck Spotify/Music volume during voice sessions (macOS-only, no Windows equivalent found).

---

## 4. Wake phrase

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/WakeWordService.swift` | `WakeWordService`, `SFSpeechRecognizer` | **On-device Apple Speech framework**, not a dedicated keyword-spotting SDK (no Picovoice/Porcupine found anywhere in `Services/`). `request.requiresOnDeviceRecognition = true`. Continuously transcribes and substring-matches against `["hey mira", "hey mirror", "hey mirra", "okay mira", "hi mira"]`. Apple's on-device session ends after ~60s; `scheduleRestart()` re-invokes every 1.2s to stay "always on." | Confirmed |

**Implication:** this is the single largest wake-word/dictation gap for Windows — Apple's on-device ASR (`Speech` framework) has no drop-in equivalent. A Windows port needs either a dedicated wake-word library (Porcupine, openWakeWord) or a locally-run STT engine (Whisper.cpp) — a materially different design, not a straight port.

---

## 5. Screen awareness

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/ScreenCaptureService.swift` | `ScreenCaptureService`, `SCScreenshotManager` | **ScreenCaptureKit**, not `CGWindowListCreateImage` — single-shot screenshots via `SCScreenshotManager.captureImage`, excludes Mira's own windows. Handles the well-known macOS-Sequoia unreliability of `CGPreflightScreenCaptureAccess()` with a persisted confirmation flag. Opens `x-apple.systempreferences:` deep links on denial. | Confirmed |
| `Mira/Services/VisionStateVerifier.swift` | `VisionStateVerifier` | Sends screenshot + condition to Anthropic (`claude-sonnet-4-6`) for strict `{satisfied, confidence}` JSON — model-based verification for the Teaching System. Network call is portable; image downscaling uses AppKit imaging (`NSBitmapImageRep`). | Confirmed |
| `Mira/Services/AppContextService.swift` | `AppContextService` | Watches `NSWorkspace.didActivateApplicationNotification`; hardcoded bundle-ID → tool-guidance map (Notion, Linear, Spotify, etc.). Bundle-ID matching has no Windows equivalent (would need process-name/executable-path matching). | Confirmed |
| `Mira/Services/ContextService.swift` | `ContextService` | Frontmost browser URL via **AppleScript** (Safari/Chrome/Arc/Firefox/Brave-specific snippets) — no Windows equivalent. Selected text via **`AXUIElement`** (`kAXFocusedUIElementAttribute`/`kAXSelectedTextAttribute`), read-only. Battery via IOKit. | Confirmed |
| `Mira/Services/ElementLocationDetector.swift` | `ElementLocationDetector` | Uses Anthropic's Computer Use API purely as a vision coordinate detector (asks the model to "click," parses the coordinate, doesn't execute it). AppKit bottom-left-origin coordinate flip is explicit and macOS-specific (simpler on Windows — no flip needed). | Confirmed |
| `Mira/Services/GroundingService.swift` | `GroundingService` | Two-tier grounding: vision (`ElementLocationDetector`) cross-checked against the **Accessibility tree** (`AXUIElementCopyElementAtPosition`) at small pixel offsets, verifying bundle-ID match and actionability. Temporarily hides Mira's own full-screen overlay windows so the AX hit-test sees through to the real target. | Confirmed |

**Windows equivalents, per confirmed macOS API:** ScreenCaptureKit → Windows.Graphics.Capture / Desktop Duplication API (different permission model — no TCC-style consent database). `AXUIElement` hit-testing → UI Automation's `ElementFromPoint` (conceptually similar, COM-based, different vocabulary). AppleScript browser-URL reading → no equivalent; would need per-browser extensions or DevTools protocol.

---

## 6. Computer control / actuation

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/AXActuationService.swift` | `AXActuationService` | **`AXUIElementPerformAction`/`AXUIElementSetAttributeValue`** — presses buttons and sets text values directly in a target app's Accessibility tree, with no cursor movement and no app activation (self-tests this explicitly via `runBackgroundActuationProbe`). Requires `AXIsProcessTrusted()` (Accessibility permission). | Confirmed |
| `Mira/Services/ActuationRouter.swift` | `ActuationRouter` | 3-tier dispatch: (1) AX background (no cursor movement) → (2) AX-located cursor (bring app forward, `ComputerUseService.click` at the AX-reported rect) → (3) `.needsVision` handoff to `ComputerUseOrchestrator`. The tiering logic itself is portable business logic; the primitives it calls are macOS-specific. | Confirmed |
| `Mira/Services/ComputerUseService.swift` | `ComputerUseService` | **Raw `CGEvent` synthetic input posted to `.cghidEventTap`** — indistinguishable from real hardware input. Hardcoded macOS ANSI virtual keycodes (not portable to Windows `VK_*` codes). Screenshot loop reuses ScreenCaptureKit. | Confirmed |
| `Mira/Services/ComputerUseOrchestrator.swift` | `ComputerUseOrchestrator` | Multi-turn Anthropic `computer_20251124` tool-use loop (model `claude-sonnet-5`) driving `ComputerUseService`; 40-step ceiling; screen-fingerprint check warns the model when a click had no visible effect. The Anthropic tool-use loop itself is portable; only the underlying input/capture primitives are macOS-specific. | Confirmed |
| `Mira/Services/CodexComputerUseService.swift` | `CodexComputerUseService` | Shells out to the `codex` CLI (`/bin/zsh -lc "codex exec ... --dangerously-bypass-approvals-and-sandbox"`), streams NDJSON events. **The actual desktop-actuation mechanism happens inside the external `codex` process** — not visible in this repo. | Confirmed (shell-out mechanism); **Unknown** what Codex does internally |
| `Mira/Services/AccessibilityService.swift` | `AccessibilityService` | **Not actuation** — wraps macOS's user *display* accessibility preferences (Reduce Motion, VoiceOver state). Easy to conflate with `AXActuationService`; flagged explicitly to avoid that. | Confirmed |
| `Mira/Services/EventTapThread.swift` | `EventTapThread` | Dedicated background `Thread`/`CFRunLoop` (kept alive via `NSMachPort`) so `CGEventTap` sources are never serviced on the main thread (macOS disables an unserviced tap after ~1s). | Confirmed |
| `Mira/Services/MediaKeyInterceptService.swift` | `MediaKeyInterceptService` | `CGEventTap` filtering undocumented `NX_KEYTYPE_*` codes to intercept volume/brightness keys; confirms this class of global tap requires Accessibility trust (re-checked on a 5s timer, torn down the instant trust is lost). | Confirmed |

**Windows equivalent summary:** `AXUIElement` actuation → UI Automation `Invoke`/`SetValue` patterns (conceptually similar "background actuation," different permission model — no macOS-style TCC grant needed, but also less consistently implemented across legacy Win32/Electron apps). `CGEvent`/`.cghidEventTap` → Win32 `SendInput`. `CGEventTap` global hooks → `SetWindowsHookEx(WH_KEYBOARD_LL/WH_MOUSE_LL)`.

---

## 7. Cursor reply bubbles

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/CursorBubbleService.swift` | `CursorBubbleService`, `CursorMessageBubbleView`, `BubbleFlowLayout` | Thin facade over `OverlayWindowManager` (in `MiraCursorManager.swift`); defines the bubble UI (custom SwiftUI `Layout` for word-wrap flow) but not the window/positioning logic. | Confirmed |
| `Mira/Managers/MiraCursorManager.swift` | `OverlayWindowManager`, `MiraCursorManager` (thin facade) | Comment explicitly documents this as a reverse-engineered reimplementation of a competing app's ("HeyClicky") cursor: the real system cursor is never hidden; a detached "companion" arrow is drawn offset from the real pointer. Position tracked via `NSEvent.addGlobalMonitorForEvents`/`addLocalMonitorForEvents` reading `NSEvent.mouseLocation` — **not** `CGEventTap`. One `NSWindow` per `NSScreen`, `level = CGWindowLevelForKey(.cursorWindow)`. | Confirmed |
| `Mira/Services/CursorCompanionManager.swift` | `CursorCompanionManager` | A **second, separate** floating panel (distinct from `OverlayWindowManager`) for agent progress/replies/questions/confirmations. Positioned via a 60fps polling `Task` loop reading `NSEvent.mouseLocation` (not an event tap or monitor) and calling `setFrameOrigin`. | Confirmed |
| `Mira/Models/CursorCompanionModels.swift` | `CursorCompanionState`, `CursorCompanionViewModel` | Pure data/state, no AppKit dependency. | Confirmed |
| `Mira/Services/PointToService.swift` | `PointToService` | Reverse-engineered "flying triangle" glide animation (hardcoded bezier/spring constants) from the same competitor product; full-screen click-through `NSWindow`. | Confirmed |
| `Mira/Services/PointFollowUpService.swift` | `PointFollowUpService` | `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown])` — explicitly does *not* require Accessibility trust (unlike a `CGEventTap`). | Confirmed |

**Cursor tracking mechanism (confirmed):** `NSEvent` global/local monitors reading `NSEvent.mouseLocation` — not a raw `CGEventTap`, contrary to a naive assumption. Windows equivalent: `GetCursorPos` polling (the polling pattern itself already ports conceptually) or a low-level mouse hook; layered windows (`WS_EX_LAYERED`/`WS_EX_TRANSPARENT`) replace the `NSPanel`/`CGWindowLevelForKey` mechanism.

---

## 8. Notifications

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Views/EventToastView.swift` | `EventToastView` | In-app SwiftUI toast, embedded inside the island's pill — **not** a system notification. No `UNUserNotificationCenter` usage. | Confirmed |
| `Mira/Services/TaskAnnouncer.swift` | `TaskAnnouncer` | Real macOS system notifications: `UNUserNotificationCenter.current().requestAuthorization` + `add(UNNotificationRequest(...))`. Also drives spoken feedback via a 3-tier fallback (RealtimeVoiceService → MisoTTS → `AVSpeechSynthesizer`) so a completion is never silent. | Confirmed |

**Two distinct concepts, do not conflate:** in-app toast (portable) vs. system banner (`UNUserNotificationCenter`, Apple-only — Windows equivalent is `Microsoft.Windows.AppNotifications`/`Windows.UI.Notifications`).

---

## 9. Daily briefing

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Views/BriefingView.swift` | `BriefingView` | Two-column layout: greeting + calendar (`EKEvent`) + last conversation snippet; battery + "Focus" memories + "Recently learned" memories. Own throwaway `EKEventStore`, separate from `CalendarTodayService`'s persistent store. **No confirmed call site renders this view anywhere in the live UI graph** — `mira_last_briefing` is written in `.onAppear` but never read elsewhere. | Confirmed code; reachability **Unknown** (likely orphaned) |
| `Mira/Services/CalendarTodayService.swift` | `CalendarTodayService` | The **actual** live calendar source backing the notch's Home tab (confirmed via `NotchHomeTabView`'s `@ObservedObject`). Handles the macOS 14 `.fullAccess` EventKit permission split. | Confirmed |
| `Mira/Services/WeatherService.swift` | `WeatherService`, `LocationProvider` | **Not a paid weather API** — calls the free public `https://wttr.in/` JSON endpoint, optionally with GPS coordinates from `CLLocationManager` (Core Location). No API key. | Confirmed |

**No scheduler/cron wiring was found that triggers a daily briefing on a timer or at login** — flagged as an active gap, not merely unconfirmed.

---

## 10. Background agents

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/AgentProcessManager.swift` | `AgentProcessManager` | Launches the Node sidecar via `Process`: resolves `node` from hardcoded Homebrew paths (`/opt/homebrew/bin/node`, `/usr/local/bin/node`, `/usr/bin/node`) or `/bin/zsh -l -c "which node"`; resolves the script via `Bundle.main.path(forResource: "server", ofType: "js")`. Passes only `SUPABASE_URL` as an env var — **no provider API keys are passed to the subprocess** (confirmed by code comment: the sidecar reaches providers only via the Supabase proxy edge functions, authorized per-request by the user's JWT). Restart with exponential backoff, capped at 5 rapid-exit attempts/60s. Reaps orphaned sidecars via `lsof -ti :4242` + `ps` + `kill()`. | Confirmed |
| `Mira/Services/AgentService.swift` | `AgentService` (Swift HTTP client) | `URLSession` client hardcoded to `http://127.0.0.1:4242`; posts to `/agent/run`, `/agent/confirm`, `/connect/:app`, `/connections`, `/connections/status`, `/disconnect/:app`. Pure networking — portable as-is. | Confirmed |
| `AgentService/src/server.ts` | Express app | `app.listen(PORT, "127.0.0.1", ...)`, `PORT = process.env.PORT \|\| 4242`. Endpoints: `/health`, `/agent/run`, `/agent/confirm`, `/connect/:app`, `/connections/status`, `/connections`. | Confirmed |
| `AgentService/src/agent.ts` | `runAgent`, `executeConfirmed`, `makeComposio` | Routes both Anthropic (`@ai-sdk/anthropic` `createAnthropic`) and Composio SDK traffic through Supabase proxy edge functions (`anthropic-proxy`, `composio-proxy`) using the caller's JWT — **no provider secret lives in the sidecar**. `SUPPORTED_TOOLKITS` hardcodes 12 integrations (gmail, googlecalendar, googledrive, googledocs, googlesheets, notion, slack, github, linear, airtable, vercel, netlify). `CONFIRM_BEFORE_RUN` gates destructive tool calls behind explicit user confirmation. Model: `claude-haiku-4-5-20251001`, capped at 5 tool-call steps. | Confirmed |
| `AgentService/package.json` | — | `express@5`, `ai`/`@ai-sdk/anthropic` (Vercel AI SDK), `@composio/core`/`@composio/vercel`. Build: `esbuild --platform=node --target=node18 --external:fsevents`, output copied directly to `Mira/Resources/server.js`. **Grep for `child_process`/`exec`/`spawn`/`process.platform`/`osascript`/`pbcopy` across `AgentService/src/` returned zero hits** — the sidecar itself is OS-agnostic. | Confirmed |
| `Mira/Services/AgentCoordinator.swift` | `AgentCoordinator` | Pure Swift task-arbitration engine (anti-starvation aging, per-project locking, capability-tag matching, preemption scoring). No AppKit/Darwin dependency beyond `ObservableObject`/`@Published` (Combine). | Confirmed |
| `Mira/Services/AgentJobStore.swift` | `AgentJobStore` | JSON file at `~/Library/Application Support/Mira/agent_jobs.json`. Uses `NSImage` (AppKit-only, for variant-preview caching) and `UserNotifications`. Confirmation gates via `withCheckedContinuation`. | Confirmed |
| `Mira/Services/BackgroundScheduler.swift` | `BackgroundScheduler` | Uses **`NSBackgroundActivityScheduler`** (AppKit-only, no Windows analog) for a 30-min "continuation" activity and a 7-day "weekly review." Also `UNUserNotificationCenter`. | Confirmed |
| `Mira/Services/CronScheduler.swift` | `CronScheduler` | `Timer.scheduledTimer` (Foundation, cross-platform) polling due crons every 60s, calling `ClaudeService.ask` directly. | Confirmed |
| `Mira/Services/ExternalTriggerRunner.swift` | `ExternalTriggerRunner` | Pure orchestration; delegates file-watching to `FileWatchService`, webhook/GitHub-push triggers to `WebhookServer`. | Confirmed |
| `Mira/Services/FileWatchService.swift` | `FileWatchService` | Header says "FSEvents-lite" but the actual mechanism is **`DispatchSourceFileSystemObject`** over a raw fd opened with `O_EVTONLY` — BSD-kqueue-backed, not the true FSEvents API, but still Darwin-only. No Windows equivalent (`ReadDirectoryChangesW` needed). | Confirmed (name doesn't match implementation) |
| `Mira/Services/WebhookServer.swift` | `WebhookServer` | Built on **`Network.framework`** (`NWListener`/`NWConnection`) — Apple-only, no Windows equivalent (needs `TcpListener`/Winsock). | Confirmed |
| `Mira/Models/AgentTaskStore.swift`, `CronModels.swift`, `TriggerModels.swift` | `AgentTaskStore`, `CronStore`, `TriggerStore` | All three persist via `UserDefaults` (JSON-encoded), not files. | Confirmed |

**Architecturally important finding:** there are **at least three independent agent-execution mechanisms** that do not call each other — (a) the Node sidecar (Composio integrations), (b) in-process Swift job runners (`WebsiteBuilderAgent`/`ResearchAgent`/etc., referenced by `AgentJobStore` but not themselves opened in this pass — **Unknown** in detail), and (c) `BackgroundScheduler`/`CronScheduler`/`ExternalTriggerRunner` calling `ClaudeService` directly. A Windows port must treat these as three separate porting efforts, not one.

---

## 11. Memories

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Models/MemoryStore.swift` | `MemoryStore`, `Memory` | Flat JSON file at `~/Library/Application Support/Mira/memory.json` (`JSONEncoder`/atomic write). Confidence model: explicit memories start at 0.95, decay −0.01/day (floor 0.10), reinforcement +0.08 (cap 1.0). **Zero references to `SupabaseService` or any network call in this file** — confirmed local-only. Pure Swift/Foundation, no AppKit — directly portable. | Confirmed |

---

## 12. Projects

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/ProjectEngine.swift` | `ProjectEngine` | Two JSON files (`projects.json`, `evidence_snapshot.json`) under the same Application-Support convention. A "project" is a metadata/audit-trail record (`MiraProject`), **not** a filesystem-folder abstraction — `filesModified` is just a deduped list of path strings. **No direct coupling to `FileWatchService`** was found; the only link is that a fired `ExternalTrigger` can *start* a project session. Crash recovery closes orphaned sessions on load. Pure Swift/Foundation — no AppKit found in this file. | Confirmed |
| `Mira/Models/ProjectModels.swift`, `ProjectEvent.swift` | `MiraProject`, `ProjectEventBus` | Pure data models; `ProjectEventBus` is a thin `NotificationCenter` wrapper (portable via swift-corelibs-Foundation, cross-platform reliability not independently verified). | Confirmed |

---

## 13. Skills

**Two entirely separate systems share a similar bundle shape but do not interact:**

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/SkillCatalog.swift` | `SkillCatalog` | **System A — "Teaching System"**: guided lessons (e.g. "Turn on Dark Mode"), not LLM prompt-skills. Bundle = `SKILL.md` (hand-parsed frontmatter, no YAML lib) + `steps.json` (curriculum, loaded lazily). Exactly 4 success-check types, one of which (`darkModeEnabled`) is macOS-specific; an unsupported check type fails the whole bundle by design ("honest failure, not a fake pass"). Storage: `~/Library/Application Support/Mira/Skills`. | Confirmed |
| `Mira/Models/MiraSkill.swift`, `MiraSkillCatalog` | `MiraSkill` | **System B — prompt-injection skills**: 24 built-in skills hardcoded as Swift source. Several reference macOS-only automation directly in their prompt text (Reminders/Notes require Automation permission; iMessage uses AppleScript + a Homebrew CLI; Spotify control is AppleScript-driven). | Confirmed |
| `Mira/Services/MiraSkillLoader.swift` | `MiraSkillLoader` | Merges built-in + "platform" (mirrored from `Bundle.main.resourceURL`, an app-bundle concept with no Windows equivalent) + "user" skill layers, plan-gated (Free: none beyond built-in; Pro: +platform; Ultra: +user-authored). In System B, the SKILL.md **body itself is the literal text injected into Claude's system prompt** — no curriculum, no success-checks (the key structural difference from System A). | Confirmed |
| `Mira/Services/SkillStore.swift` | `SkillStore` | Persists only the *active skill ID set* via `UserDefaults`; content comes from `MiraSkillLoader`. | Confirmed |
| `Mira/Services/PythonSkillRunner.swift` | `PythonSkillRunner` | **Confirmed shells out to Python.** No bundled interpreter — relies on system `python3` via a `venv` at `~/Library/Application Support/Mira/python-skills-venv`, invoked as `venvRoot/bin/python3` (POSIX layout; Windows venvs use `Scripts\python.exe`). Execution is hardcoded `/bin/zsh -lc "<python> <script> < <argsfile>"` — POSIX shell, POSIX quoting, POSIX stdin redirection, none of which exist on Windows as-is. 13 named skills, several with pip deps (`pdfplumber`, `python-docx`, `openpyxl`, etc.); several stdlib-only skills (`imessage_read`, `findmy_devices`, `reminders_rw`, `notes_rw`) rely on macOS-only mechanisms (`osascript`) internally with no Windows equivalent at all. | Confirmed |
| `Mira/Services/CommunitySkillService.swift` | `CommunitySkillService` | Talks to `skills-catalog` (public) and `skills-publish` (authenticated) Supabase edge functions. Installed community skills are **never auto-activated** (explicit comment). Pure `URLSession` — portable. | Confirmed |
| `supabase/functions/skills-publish/index.ts` | — | Server-side frontmatter parser explicitly mirrors the client parser "line-for-line." Runs an **AI moderation pass** (direct Anthropic call, `claude-haiku-4-5-20251001`) before approving/rejecting/queuing a published skill. Entirely portable Deno/TypeScript. | Confirmed |
| `supabase/migrations/20260710220000_community_skills_catalog.sql` | `community_skills` table | Body stored in-row (no storage bucket). RLS: public read only where `status='approved'`; no client INSERT/UPDATE policy — all writes go through the edge function under the service role. | Confirmed |

---

## 14. Saved content

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/OutputStore.swift` | `OutputStore` | JSON registry (`output-registry.json`) pointing at real files under `~/Library/Application Support/Mira/Projects/{Websites\|Research\|Documents\|Apps}/{uuid}/`. Registry entries whose file was externally deleted are dropped on load (self-healing). Versioning archives prior HTML into `history/v{n}.html` before overwrite. Export uses **`NSFileCoordinator`** (`.forUploading`) — a Darwin-specific "coordinated zip" trick with no direct Windows equivalent. Preview thumbnails use `NSImage`/`NSBitmapImageRep`. **No Supabase/cloud sync of output content found** — publishing metadata records only a third-party deploy URL. | Confirmed |
| `Mira/Models/OutputEntry.swift` | `OutputEntry`, `OutputType` | Pure data, migration-safe `Codable`. Fully portable. | Confirmed |
| `Mira/Services/FileShelf.swift` | `FileShelfService` | Real files copied into `~/Documents/Shelf`; the in-memory list is just a re-scan of that folder (no separate index). Plan-gated (5 items free-tier, unlimited Ultra). Uses **AirDrop** (`NSSharingService(named: .sendViaAirDrop)`) — Apple-only, no Windows equivalent. | Confirmed |

---

## 15. Daily briefing / Notifications / Authentication / Subscriptions / Supabase / Model routing / Local storage / Cloud services / API proxies / Updates and distribution

These are covered above (§8, §9) and below.

### Authentication

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/SupabaseService.swift` | `SupabaseService`, `SupabaseSession` | Email/password (`/auth/v1/token?grant_type=password`), signup, native Sign in with Apple (`grant_type=id_token`), and a **browser-based Apple OAuth flow** (`mira://auth-callback`) used specifically because native Sign in with Apple's entitlement is unavailable to a Developer-ID (non-App-Store) app. Session persisted in `UserDefaults` (not Keychain) as a `Codable` struct. Auto-refresh: a repeating 120s `Timer` plus an `NSWorkspace.didWakeNotification` observer (a run-loop `Timer` is suspended during sleep, so wake-from-sleep needs its own refresh trigger). Single-flighted refresh to avoid double-rotating the single-use refresh token. | Confirmed |
| `Mira/Services/AccountService.swift` | `AccountService` | Wraps `SupabaseService`; on sign-up, calls `check-device` **before** creating the account to block a second free account on the same Mac; on any sign-in, fires `register-device` which can 409 and force a sign-out if another free account already owns the device hash. | Confirmed |
| `Mira/Services/DeviceFingerprintService.swift` | `DeviceFingerprintService.deviceHash` | SHA-256(IOKit `IOPlatformSerialNumber` + a Keychain-persisted UUID, `Synchronizable=false`). **Both IOKit hardware-serial lookup and Keychain Services are macOS-only** — a Windows port needs a different fingerprint (e.g. WMI `Win32_ComputerSystemProduct.UUID`) + DPAPI/Credential Manager for the persisted ID. | Confirmed |
| `supabase/functions/check-device/index.ts`, `register-device/index.ts` | — | `check-device` is public/unauthenticated (by design — runs before an account exists). `register-device` requires the freshly-issued JWT. Device lock enforced via a **partial unique index** (`profiles_device_free_uniq` on `device_id_hash` where `plan='free'`) — paid accounts are exempt. | Confirmed |

### Subscriptions

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/EntitlementService.swift` | `EntitlementService`, `SubscriptionPlan` | Client-side plan cache (`UserDefaults`), explicitly documented as **UX-only** — the comment in `docs/architecture/backend_secrets_proxy.md` and the code itself agree the server (`profiles.plan`) is authoritative. `can(_:)` gates `runAgents`/`buildWebsites`/`buildApps`/`useScreenGuidance`/`deepResearch`/`contentGeneration`/`unlimitedChat` by plan; `useVoiceMode` returns `true` unconditionally client-side (actual voice quota is enforced server-side per §"Supabase" below). Polls the server for up to ~2 minutes after a checkout/portal action to reflect upgrades without a restart. | Confirmed |
| `Mira/Services/StripePurchaseService.swift` | `StripePurchaseService` | Opens Stripe Checkout/Billing Portal in the **default browser** (`NSWorkspace.shared.open`), not an in-app webview — the customer ID is resolved server-side from the JWT, never held client-side. | Confirmed |
| `supabase/functions/stripe-checkout/index.ts`, `stripe-portal/index.ts`, `stripe-webhook/index.ts` | — | `stripe-webhook` is deployed `--no-verify-jwt` (Stripe carries no Supabase JWT) and instead verifies `Stripe-Signature` via HMAC-SHA256 against `STRIPE_WEBHOOK_SECRET`. Updates `profiles.plan`/`stripe_customer_id`/`stripe_subscription_id` on `checkout.session.completed`/`customer.subscription.updated`/`customer.subscription.deleted`. Non-active statuses (`past_due`, `canceled`, `unpaid`) downgrade to `free`. | Confirmed |

### Supabase / API proxies / secrets

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/MiraBackend.swift` | `MiraBackend.useProxy` | **`static let useProxy = true`** in the current source — i.e. proxy mode is the live default, not a future flag. Routes Anthropic, OpenAI (chat + TTS), and AssemblyAI traffic through Supabase edge functions, authorizing with the signed-in user's JWT rather than an embedded provider key. Implements reactive 401-refresh-and-retry (`proxyData`/`proxyBytes`) so a stale token self-heals without surfacing an error. | Confirmed |
| `supabase/functions/_shared/auth.ts` | `requireUser`, `requireEntitlement`, `checkQuota`, `meter`, `checkVoiceQuota`, `addVoiceUsage` | Shared middleware. `requireUser` verifies the JWT via `admin.auth.getUser(jwt)` (service-role client, never exposed to clients) and loads `plan` from `profiles` — **identity always comes from the verified token, never from client-sent fields.** Per-plan daily token budgets (`free: 100k, pro: 2M, ultra: 10M`, input+output combined) enforced via `checkQuota`/`meter` against the `usage` table. Voice has a **separate** cap (`checkVoiceQuota`/`addVoiceUsage`, via `voice_usage` table and `daily_voice_caps(plan)` SQL function) because realtime audio isn't token-metered. | Confirmed |
| `Mira/Config/AppSecrets.swift` | — | **File does not exist in this checkout** — listed in `.gitignore` (`Mira/Config/AppSecrets.swift`). Its current contents (which provider keys, if any, are still embedded) are **Unknown — not confirmed in inspected source.** The intended end-state, per `docs/architecture/backend_secrets_proxy.md`, is zero provider secrets client-side; `MiraBackend.useProxy = true` is consistent with that end-state having shipped, but this ledger cannot confirm `AppSecrets.swift`'s actual current content. | **Unknown** (file absent from checkout by design) |
| `supabase/migrations/20260614120000_secrets_proxy.sql` | `profiles`, `usage`, `add_usage()` | `profiles.plan` is the single source of truth for entitlement, updated only by the Stripe webhook (service role); RLS allows a user to `select` only their own row, no user-writable policy exists on either table. | Confirmed |
| `supabase/migrations/20260626120000_device_lock_and_spend_alarm.sql` | `spend_alarm_log`, pg_cron job `mira-spend-alarm` | **A cleartext bearer/cron-secret value is committed directly in this migration file**, embedded in the SQL `pg_cron` `http_post` header (`x-cron-secret`). This is a real secret checked into source control (not a placeholder). Redacted here per this audit's instruction not to reproduce secret values — see [SECURITY_AND_PRIVACY.md](SECURITY_AND_PRIVACY.md) for the finding and remediation. | **Confirmed finding; value redacted in this ledger** |
| `Mira/Mira.entitlements` | — | Exactly 4 entitlement keys: `automation.apple-events`, `device.audio-input`, `network.client`, `personal-information.calendars`. **No `com.apple.security.app-sandbox` key present** — the app is confirmed **not sandboxed**, consistent with unrestricted shell/AppleScript tool calls elsewhere. | Confirmed |

### Model routing

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/RouterService.swift` | `RouterService`, `MiraRoute`, `route()`, `classifyIntent()` | Two-tier: (1) a **pure, synchronous, keyword/regex classifier** (`route()`, no LLM call) covering ~30 route cases; (2) for ambiguous prompts, a Claude Haiku (`claude-haiku-4-5-20251001`) "gate" call (`haikuClassify`) that returns `{route, confidence, explanation}` JSON, with fallback to the deterministic result on any failure. | Confirmed |
| `Mira/Services/EngineRouter.swift` | `EngineRouter` | Rule-based (not LLM) selector between Codex and Claude for desktop-control tasks; hardcoded app blocklist for Codex (terminal, password managers); Claude is primary with Codex as a silent failover. | Confirmed |
| `Mira/Services/ClaudeCodeBridge.swift` | `ClaudeCodeBridge` | Shells out to a `claude` CLI binary, resolved from 3 hardcoded candidate paths; `--dangerously-skip-permissions`, streams NDJSON. | Confirmed |
| `Mira/Services/MiraToolService.swift` | `runCodingAgent` | A **second**, separate Claude Code invocation path with a **hardcoded, single-developer's home-directory path** (`/Users/trevonbarbour/.local/bin/claude`) — a concrete portability bug even on macOS, not to be reproduced on Windows. | Confirmed |
| `Mira/Services/CodexService.swift` | `CodexService` | Shells out to `codex exec` via `/bin/zsh -lc`, login shell specifically so `nvm`-installed binaries resolve. | Confirmed |
| `Mira/Services/CodexMCPClient.swift`, `MiraMCPServer.swift` | — | A persistent "warm" `codex mcp-server` subprocess talked to via JSON-RPC 2.0 over stdio, plus an in-process MCP server (`Network.framework`/`NWListener`, loopback-only) exposing `MiraToolService` as MCP tools back to the spawned Codex process — bidirectional MCP. Dangerous tools gated behind a native `NSAlert` confirmation (AppKit-only). | Confirmed |

### Local storage

- **Dominant pattern:** JSON files under `~/Library/Application Support/Mira/*.json`, written via plain `FileManager`/`JSONEncoder`/`JSONDecoder` — confirmed in 25+ files. This exact pattern (Foundation-only, no AppKit) is directly portable once the directory-resolution call is retargeted to a Windows path (e.g. `%LOCALAPPDATA%\Mira`).
- **`UserDefaults`** — 57 files, 114+ call sites for settings/flags. Apple-Foundation-specific API; no 1:1 Windows equivalent exists in swift-corelibs-Foundation with confirmed parity — flagged **Unknown** whether it persists reliably under a Windows Swift runtime without dedicated testing.
- **Keychain (`Security` framework)** — confirmed in `DeviceFingerprintService.swift` and `SpotifyAuthService.swift` (OAuth refresh token, explicitly `Synchronizable=false`). No Core Data, no bundled SQLite/GRDB found anywhere in the app target (the only `sqlite3` references are inside bundled Python skill *scripts*, not the Swift app).

### Updates and distribution

| File | Symbol | Behavior | Status |
|---|---|---|---|
| `Mira/Services/UpdateService.swift` | `UpdateService`, `SPUStandardUpdaterController` | **Sparkle** (confirmed via `import Sparkle`), macOS-only auto-update framework — no cross-platform version exists. Works around Sparkle's modal UI conflicting with the app's accessory-activation-policy notch panel. | Confirmed |
| `appcast.xml`, `Mira/Info.plist` | `SUFeedURL`, `SUPublicEDKey` | Feed hosted on **Supabase Storage**, not Sparkle's typical GitHub-Pages pattern. Confirms **arm64-only** (`sparkle:hardwareRequirements`), **macOS 14.0+ minimum**, Ed25519-signed enclosures. | Confirmed |
| `scripts/build_release.sh` | — | Developer-ID signing (team `7FD7W8SX34`) + `notarytool` notarization + `stapler` stapling, DMG via `create-dmg`, distributed via GitHub Releases + Supabase Storage — **confirmed direct-download distribution, not the Mac App Store.** Re-signs Sparkle's nested binaries individually (a documented Sparkle/notarization requirement). | Confirmed |
| `project.yml` | — | `CODE_SIGN_STYLE: Manual`, hardened runtime (`--options=runtime`), `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. | Confirmed |

---

## Explicit UNKNOWNs carried into the other Phase 0 docs

- Current contents of `Mira/Config/AppSecrets.swift` (file absent from this checkout by design — gitignored).
- Whether `BriefingView` is reachable from any live navigation path (code exists; no call site found).
- The internal actuation mechanism used by the external `codex` CLI process (opaque to this repo).
- Whether `AVAudioEngine` mic-tap contention between `RealtimeVoiceService`/`AssemblyAIStreamingService`/call-transcription's `MicAudioCapture` is actually resolved at runtime, or remains an open issue as one file's own comment states.
- Implementation detail of `WebsiteBuilderAgent`/`ResearchAgent`/`ContentAgent`/`PublishingAgent`/`WebsiteHealthAgent` (referenced by `AgentJobStore` but not opened in this pass).
- Whether `UserDefaults`/`FileManager` application-support path resolution behaves correctly under a Windows Swift runtime, if Swift itself were ever used cross-platform here (not assumed in this audit's recommendations — see [WINDOWS_ARCHITECTURE.md](WINDOWS_ARCHITECTURE.md), which recommends **not** attempting to run Swift on Windows).
- Contents of several View files not read line-by-line (`ProjectsTabView.swift`, `OutputDetailView.swift`, `AgentOutputsView.swift`, `SkillsTabView.swift`, `CommunityBrowseView.swift`, `CronsTabView.swift`, `TriggersTabView.swift`) — confirmed to exist and sized, presumed SwiftUI+AppKit by strong pattern consistency with every fully-read View file, not independently re-verified line-by-line.

## macOS-tested vs. Windows-tested vs. source-confirmed

**Everything in this ledger is "confirmed by reading source" on a Windows machine, with no macOS runtime available in this session.** Nothing here has been executed, and no claim should be read as "verified to work on macOS today" — only as "this is what the checked-in source does when read." Any Phase 1+ work must re-validate macOS behavior on an actual Mac before treating this ledger as a spec to build against, particularly for timing-sensitive AppKit/Accessibility/CGEventTap behavior that cannot be fully understood from source alone.
