# MacNotch Parity Audit

**Source of truth:** macnotch.io (feature copy extracted from the site's i18n bundle,
`/assets/index-lFRQbvHY.js`), 32 product screenshots, and 4 demo videos
(`demo-00..03.mp4`, frame-sampled at 1/3s).
**Audited against:** Mira `feat/windows-mira`, 260 Swift files, 2026-07-30.

---

## 1. What MacNotch actually is

MacNotch is **not** an AI product. It is a **modular container** — a shell that hosts
~20 independent panels at the top of the screen. Everything Tre reacted to in those
screenshots is the *shell*, not any one module: the black rounded slab welded to the
notch, the circular module dock floating below it, the vertical icon rail on the right
edge, and the fact that every panel obeys the same geometry.

Positioning claims from the site:

> "A powerful modular dashboard at the top of your Mac. Works with or without a physical
> notch and on multiple displays." · "MacNotch turns the top of your screen into a
> practical control center. Everything below is optional. Enable, tune, or hide each
> piece in Settings." · Requires macOS 14+, Apple Silicon or Intel, **a physical notch is
> optional**.

Business model, for reference: 14-day trial, one-time license *or* subscription, 3 Macs
per license, key format `MN-XXXX-XXXX`, Stripe + Setapp, Sparkle updates, localized in
11 languages.

### 1.1 The shell — this is the part to copy exactly

Derived from the videos, not the marketing copy.

| Element | Behavior |
|---|---|
| **Slab** | Black, ~22pt corner radius on the bottom corners only; top edge fused flush to the physical notch / menu-bar line so it reads as one object growing *out of* the notch. Never a floating window with a visible top edge. |
| **Header row** | Inside the slab, at menu-bar height: module title (bold, left) + contextual subtitle/pill (e.g. `Dashboard  [Work >]`, `Calendar  July 2026  [Today]`, `Notes 7`), then right-aligned circular icon-buttons for module-specific actions (refresh, download, info, settings, search). |
| **Module dock** | A **detached horizontal row of ~16 circular black pill buttons floating below the slab**, gapped from it. This is the module switcher. It appears on expand and disappears on collapse. Count varies with enabled modules (5 in a lean config, 16 in a full one). |
| **Right rail** | A **vertical column of small icons on the slab's right edge**, partially clipped — a secondary/overflow module switcher. Icons shift as you move through modules. |
| **Collapse affordance** | A small circular ⤡ button at the **bottom-right inside corner** of the slab, always in the same spot for every module. |
| **Sizing** | Height is **per-module**, not fixed. Snap Zones is short and wide; Bluetooth is tall; Media is medium. The slab animates between sizes. Some modules have an "expanded height" setting (Screen Time, AI Coding). |
| **Layout grammar** | Nearly every module is **2- or 3-column**: a narrow left index/sidebar (lists, filters, counts) + a wide right detail pane. Calendar = month grid + agenda. Todo = All/Active/Done/Trash + task list. Notes = note list + editor. Screen Time = insights sidebar + donut/ranking. Pomodoro = timer + presets + focus target. |
| **Drill-in** | Modules push a detail view **in place** with a `‹ Back` chip in the header and a context pill (`‹ Back  [≔ in Reminders]`). No new windows, ever. |
| **Collapsed strip** | When collapsed, the notch becomes a thin live strip that **rotates** through sources: media (album art left, waveform right), timers, calendar, Bluetooth, app updates, unread-notification glance. Widens briefly on track change. Optional hover-reveal prev/play/next. |
| **Preview mode** | When a Settings pane is open, the notch shows a **live static preview** of that overlay with an amber warning in the header (`Editing Snap Zones in Settings. Snap inactive.`) and an eye icon + `Preview mode` label. |
| **Settings** | A separate conventional macOS window — light-mode, sidebar (APP / NOTCH / MODULES sections), search field, disclosure rows. Deliberately *not* in the notch. |

---

## 2. Complete module inventory

Verbatim capability descriptions from the site. This is the checklist.

### Daily & work

| Module | Capability (from site) |
|---|---|
| **Dashboard** | Profiles with Focus and time-based switching. Weather; Spotify, Apple Music, plus Plex, NetEase Cloud Music, or VLC cards when installed and reporting to Now Playing; app and folder launcher (icons, list, or paginated sets) plus Actions shortcuts; optional extra folders to scan for apps; quotes, day progress, screen time, quick toggles (optional Persist Never Sleep with Launch at Login); shortcuts and events; mirror. **Four widget slots.** |
| **Media** | Album art and gradients; reliable Apple Music artwork. Full transport for Spotify, Apple Music, Plex, NetEase, VOX, VLC via macOS Now Playing, plus browsers and system audio. **Bars or spectrum visualization.** Synced **lyrics** (screenshots show a scrolling lyric pane with the active line bolded). Optional hover-reveal prev/play/next in the collapsed strip. |
| **Calendar** | Upcoming events and reminders from macOS. Search loaded items by title, location, notes, or calendar name; overdue and other reminder filters. Countdowns, details, and **meeting awareness through Focus integration**. Month grid + agenda; Day/Overdue/Upcoming/All filter chips with counts. |
| **Todo** | Add, complete, delete, and restore tasks. Trash with retention. **Stays in sync with macOS Reminders.** |
| **Notes** | Scratchpad in the notch. Create and open notes from the dashboard for quick capture. Rich-text toolbar (Bold/Italic/Strike/Code/List/Number/Heading). |
| **Pomodoro** | Work and break cycles you can customize, with progress in the UI, completion sounds, and an optional **Timer Done overlay** in the notch. Presets (Work/Short Break/Long Break/Quick Timer/Custom), reorderable. **Focus Target** — attach the timer to a specific event/reminder/task from today's schedule. |
| **Day Progress** | One timeline for today from calendar events, reminders, and tasks, with an optional **bedtime marker**. Sources under Settings → Day Progress; optional Today summary column and a dashboard widget. Completion % bar, "Next in 28m" pill. |
| **Screen Time** | Category charts, ranked apps, and **app-switch counts** in a dedicated module. Usage follows the frontmost app and stays on the Mac. Optional insights sidebar and expanded height; dashboard widget for today's donut. Day reset, categories, colors, excluded apps in Settings. |
| **Keyboard Shortcuts** | Dedicated shortcut settings for notch **Snooze** and module navigation. Record combinations quickly, clear or replace them, tune behavior such as **Only when hovering** plus snooze duration. Accessibility unlocks cross-app shortcuts. |
| **Notifications** | Your alerts, centered in the notch: scan what arrived, clear the noise, and **reply without leaving the flow** (inline reply field with mic, emoji picker, voice-note, send). Optional unread glance in the collapsed strip with app icon and name. |

### Code, AI & language

| Module | Capability |
|---|---|
| **AI Coding (Beta)** | Claude Code and Cursor Agent sessions in one list, with **live status, recent messages, and quick Allow / Deny when the CLI is waiting**. Expandable height. Drill-in shows the waiting prompt, the tool chips (`Await`, `Shell`, `Write`, `TodoWrite`, `SemanticSearch`), and the last response. |
| **Code hosting** | GitHub pull requests, GitLab merge requests, Bitbucket pull requests waiting on your review, plus optional ones you opened. Providers/repos in Settings; PAT stored locally. Second tab: **Pipelines** with per-job pass/fail chips and "Open in browser". |
| **Translation** | Translate with an LLM through **OpenAI or Ollama**. Choose provider, model, and languages in Settings. Two-pane source/target with AUTO ↔ language pickers and a swap button. |

### Notch & system

| Module | Capability |
|---|---|
| **Live Activities** | Collapsed strip rotates media, timers, calendar, Bluetooth, and app updates. Per-source media filters, a brief wider layout on track change, unread-notifications glance. **Volume and Brightness HUD** plus short notices. Same on external displays. Expanded view lists active activities with a **Focus/Unfocus** toggle per activity. |
| **Drop Actions** | Drop files on the notch: **Shelf, AirDrop, iCloud, zip, unzip, image convert (PNG/JPG/HEIC), move, copy, open with, Music, trash, eject removable volumes**. Add an **Expand tile** to split the list into two rows; hover Expand to grow the notch. Order, folders, dividers, width in Settings. Up to 8 actions, minimum 2. |
| **Snap Zones** | Drag a window toward the top of the screen to open **layout tiles in the notch** — halves, thirds, quarters, maximize, and more. Reorder tiles, choose which layouts appear; **richer window previews when macOS allows**. Up to 10 zones, min 1, plus **custom zones**. Live thumbnail of the dragged window follows the cursor; the hovered tile highlights; release snaps. |
| **Shelf** | Carousel stash for files: drop in, drag out. Optional Shelf tile via Drop Actions. Select-all / clear / Move / Copy / trash actions in the header. |
| **Bluetooth** | Connected gear with battery levels: AirPods, headphones, mice, keyboards, trackpads, controllers. **Low-battery alerts.** Per-device disconnect. |
| **System Analytics** | Live CPU, RAM, storage with visual ring indicators. Two densities: compact (Resources / Connectivity / Storage) and detailed (CPU, Memory, Storage, Network, Battery, Free Disk). |
| **Multiple Screens** | Choose which displays show the bar; same dashboard on any display; works with no physical notch. |
| **Event Reminder overlay** | (demo-03) Meeting alert takes over the notch: title, time, duration, location, **Join Microsoft Teams** button, Snooze / Dismiss / Dismiss All, a live "Started N seconds ago" counter, and a Focus pill. |
| **Support & Feedback** | Feedback with optional reply email, App help, app review / Setapp rating. |
| **Screen Clean** | Listed in the permissions copy as an Accessibility consumer. |
| **Hide from capture** | Settings → General → *Show Notch in Screenshots & Recordings* — can exclude itself from screenshots, recordings, and screen sharing. |

### Permissions MacNotch requests (only when the matching feature is enabled)

Accessibility (window snap detection, Screen Clean, AI Coding keystrokes to terminal,
notification-banner observation, cross-app shortcuts) · Full Disk Access · Camera
(mirror widget) · Calendars + Reminders · Bluetooth · Automation/AppleScript (media
transport for Spotify/Apple Music, some Dashboard quick toggles) · Screen Recording
(richer window thumbnails in snap preview).

---

## 3. Mira gap matrix

Legend — **✅ have** · **🟡 partial** · **❌ missing**

### Shell

| MacNotch shell element | Mira today | Status |
|---|---|---|
| Notch-fused expanding slab | `MiraIslandView`, `NotchManager`, `AnimationController` (`IslandState.collapsed/.expanded`). Top edge fused to notch was explicitly fixed 2026-07-05. | ✅ |
| Per-module variable height | Island animates, but tab content is not height-negotiated per module. | 🟡 |
| Circular module dock below slab | `MiraDockView` + `MiraDockManager` exist — but it's a **widget** dock (9 `DockWidgetType`s), not a **module switcher**. | 🟡 |
| Right-edge vertical icon rail | — | ❌ |
| Standard bottom-right ⤡ collapse | — (no consistent collapse affordance) | ❌ |
| 2/3-column index + detail grammar | Mira tabs are mostly single-pane. `HomeTabView` is 3 side-by-side cards, which is the closest. | 🟡 |
| In-place `‹ Back` drill-in | — | ❌ |
| Rotating collapsed live strip | `SharedStatusView` renders 5 *voice* states (idle/listening/thinking/working/speaking) + `NotchEyeView`. There is no media/timer/calendar/Bluetooth **rotation**. | 🟡 |
| Settings as separate light-mode window | `SettingsView` exists. | ✅ |
| Live "Preview mode" while editing settings | — | ❌ |
| Multi-display | `NSScreen.screens` used in 8 managers incl. `NotchGeometryProvider`. | ✅ |
| Hide from screenshots/recording | — | ❌ |

### Modules

| Module | Mira today | Status |
|---|---|---|
| Dashboard / widget slots | `MiraDockView`: 9 widgets (clock, weather, nowPlaying, battery, appLauncher, pomodoro, toggles, soundMeter, systemStats), reorderable + persisted (`mira_dock_widget_order_v2`). **No profiles, no Focus/time-based switching, no 4-slot model, no mirror widget, no quotes.** | 🟡 |
| Media | `NowPlayingService`, `MusicControlService`, `MediaControls`, `MediaKeyInterceptService`, `SpotifyAuthService` + a working Spotify search→play path. **No lyrics, no spectrum/bars visualization, no Plex/NetEase/VOX/VLC, no gradient album treatment.** | 🟡 |
| Calendar | `CalendarTodayService`, `EKEvent` in 5 files, `CalendarCard` on Home. **Read-only "today" card. No month grid, no agenda, no search, no reminder filters, no countdowns, no Focus meeting awareness.** | 🟡 |
| Todo | `EKReminder`: **0 hits.** No Reminders sync at all. | ❌ |
| Notes | — | ❌ |
| Pomodoro | `PomodoroService` — full focus/short/long/sessions state machine, `pom_*` defaults, dock widget. **No presets list, no Focus Target, no Timer Done overlay.** | 🟡 |
| Day Progress | `DayProgress`: **0 hits.** | ❌ |
| Screen Time | `ScreenTime`: **0 hits.** No frontmost-app usage tracking, no categories, no app-switch counts. | ❌ |
| Keyboard Shortcuts (Snooze, module nav, hover-only) | Mira has global hotkeys (⌃⌥D draw, ⌃⌥V, ⌃⌥S dictate, ⌘⇧M dock). **No recorder UI, no notch Snooze, no module navigation bindings, no "only when hovering".** | 🟡 |
| Notifications (read + inline reply) | `UNUserNotification` appears in 4 files but all are Mira **posting** its own notifications. No banner observation, no notification center read, no inline reply. | ❌ |
| AI Coding (Beta) | **Mira is ahead here.** `ClaudeCodeBridge`, `CodexService`, `CodexComputerUseService`, `CodexMCPClient`, `AgentHUDView`/`AgentHUDColumnView`, `AgentJobStore`, `AgentTaskManager`, `AgentActivityChipView`, bidirectional MCP. Missing only the **Allow/Deny-when-waiting** affordance in a notch module and the unified Claude-Code + Cursor session list. | 🟡→✅ |
| Code hosting (GitHub/GitLab/Bitbucket) | `GitLab`/`Bitbucket`: **0 hits.** | ❌ |
| Translation | 8 files mention translation but it is LLM prompt plumbing, not a translate module. | ❌ |
| Live Activities | `SystemHUDView`, `BrightnessControl`, `SystemVolumeControl`, `EventToastView`. **No activity registry, no rotation, no per-activity Focus/Unfocus.** | 🟡 |
| Drop Actions | `FileShelf` handles drop → copy into `~/Documents/Shelf` + `airdrop()`. **No action grid, no iCloud/zip/unzip/convert/move/copy/open-with/Music/trash/eject, no Expand tile, no ordering UI.** | 🟡 |
| Snap Zones | `SnapZone`: **0 hits.** No window drag detection, no tiles, no AX window positioning. (`AXActuationService` sets AX attributes for *automation*, so the primitive exists.) | ❌ |
| Shelf | `FileShelf` + shelf tab, real folder copy, verified. **No carousel, no multi-select/Move/Copy header actions.** | 🟡 |
| Bluetooth | `IOBluetooth`/`CBCentralManager`: **0 hits.** | ❌ |
| System Analytics | `SystemStats` + `systemStats` dock widget. **No dedicated module, no compact/detailed density, no network throughput, no ring indicators.** | 🟡 |
| Event Reminder overlay | `EventToastView` exists. No Join-meeting button, no snooze/dismiss-all, no elapsed counter. | 🟡 |
| Support & Feedback module | — | ❌ |
| Licensing (trial, key, 3 devices, unregister) | Stripe subscription paywall shipped (`StripePurchaseService`, `PaywallView`, `EntitlementService`, `DeviceFingerprintService`). **Different model — subscription-only, no lifetime key, no key entry, no device slot manager.** | 🟡 |

### What Mira has that MacNotch does not

Voice (Realtime, wake word, barge-in), autonomous computer use, teaching/learn-along,
Skills, Crons/Triggers, Agents that build websites, Clipboard history + multi-copy queue,
Dictate Anywhere, draw-on-screen context, camera tab, knowledge import, Projects/Threads.

**Scoreboard:** of ~22 MacNotch modules — **1 clearly ahead (AI Coding), 10 partial,
11 missing outright.** Of 12 shell elements — 3 done, 4 partial, 5 missing.

---

## 4. Honest read before you build

Two things worth saying plainly, then the plan either way.

1. **The shell is the product, the modules are the moat-less part.** Every module here is
   a well-understood macOS API surface — EventKit, IOBluetooth, MediaRemote, AX. What
   makes MacNotch feel expensive is that 22 panels obey one geometry with zero variance.
   If Mira ships 8 modules that each look slightly different, it will read as *worse*
   than shipping 3 that are pixel-identical. **Build the shell contract first and refuse
   to merge a module that violates it.**

2. **This is a different product thesis from Mira's.** MacNotch is a deterministic
   control center — glanceable, zero-latency, no model in the loop. Mira is an AI
   companion. Bolting 22 deterministic panels on doesn't automatically make Mira
   MacNotch; it makes Mira a bigger app. The version that wins is where the modules feed
   the AI: Mira sees your Screen Time, your calendar, your PR queue, your notifications —
   and *acts*. Frame every module as "AI-legible surface" and the two theses merge.
   Frame them as "features to match" and you're doing 22 units of catch-up work with no
   differentiation.

Neither point is a reason not to build it — the ask is clear and the target is a good
one. It's a reason to sequence it shell-first and wire each module into context.

---

## 5. Build order

**Phase 0 — Shell contract (blocks everything).** Define `NotchModule` protocol:
`title`, `headerAccessories`, `preferredHeight`, `content`, `detail(push/pop)`. Build
the circular module dock (switcher, not widgets), the right-edge rail, the standard
bottom-right ⤡, the in-place `‹ Back` chip, and per-module height negotiation. Nothing
else merges until an existing tab is ported onto it.

**Phase 1 — Cheap wins on APIs Mira already touches.** Bluetooth (IOBluetooth, ~1 day),
System Analytics module (SystemStats already exists), Calendar module proper (EventKit
already linked), Todo + Reminders sync (EKReminder), Notes.

**Phase 2 — The two that make people install it.** Snap Zones (window drag detection →
tiles in notch → AX reposition; this is the single most-demoed feature) and Drop Actions
(expand `FileShelf` into the full 11-action grid + Expand tile).

**Phase 3 — Live layer.** Live Activities registry + rotating collapsed strip, Volume/
Brightness HUD unification, Event Reminder overlay with Join, Notifications module with
inline reply (needs Accessibility banner observation).

**Phase 4 — Depth.** Screen Time tracker, Day Progress timeline, Dashboard profiles with
Focus/time switching + 4-slot model, Media lyrics + spectrum, Code hosting, Translation,
AI Coding module surfacing Allow/Deny.

**Cross-cutting:** hide-from-capture toggle, preview-mode-while-editing-settings,
keyboard shortcut recorder + Snooze, and a Settings IA that mirrors MacNotch's
APP / NOTCH / MODULES sidebar.

---

## 6. Measured from the installed app (MacNotch 1.9.8.8)

Taken from the shipped bundle, the preference store, and live window-server probing on
a **notchless** Mac (1728×1117 pt, 2×). Not from decompilation.

### 6.1 Window geometry — real numbers

Probed via `CGWindowListCopyWindowInfo`. Both windows are **horizontally centered**.

| State | Layer | x | y | w | h |
|---|---|---|---|---|---|
| Notch container, collapsed | 26 | 399 | 0 | **930** | **112** |
| Notch container, open (Dashboard, two rows) | 26 | 256 | 0 | **1215** | **370** |
| Menu-bar mask | 25 | 0 | 0 | **1728** (full width) | **33** |

Three things fall out of this:

1. **It is one container window that resizes**, not a stack. Layer 26 = `NSStatusWindowLevel + 1`.
2. The container is **much taller than the visible slab** in both states (112 pt collapsed
   against a ~33 pt visible strip). The surplus is hover hit-area plus shadow room — the
   window is oversized so hover arms before the pointer touches anything visible, and so
   the drop shadow isn't clipped. Mira's island window should do the same.
3. **The menu-bar mask only exists while open.** A full-width 1728×33 window at layer 25
   blanks the real menu bar whenever the notch is open, which is what makes the slab read
   as part of the system rather than a floating panel. Localizable.strings confirms the
   intent: *"Clears the menu bar while the notch is open. Click it to use the real menu
   bar temporarily."*

**Hover opens it** — no click required. Container went 930×112 → 1215×370 on
`mouse_move` to the top-center and back on mouse-out.

### 6.2 Dashboard schema — from `com.macnotch.app` prefs

The marketing "four widget slots" is really **eight**: `dashboardLeftWidget`,
`CenterWidget`, `RightWidget`, `FourthWidget` … `EighthWidget`, with
`dashboardTwoRowsEnabled` turning on the second row of four and
`dashboardTwoRowsNotchExpandedHeight` growing the notch to fit.

Six factory profiles ship, each a full dashboard config:

| Profile | Icon | Color | Left | Center | Right | Fourth | Header |
|---|---|---|---|---|---|---|---|
| Quick | `rectangle.split.3x1` | `#5eead4` | Quick toggles | Screen Time | Apps | Actions | Dashboard |
| Work | `briefcase.fill` | `#B78A65` | Events | Apps | Pomodoro | Day progress | Dashboard |
| Personal | `person.fill` | `#a78bfa` | Summary | Apps | Bluetooth | Media | Dashboard |
| Focus | `leaf.fill` | `#047857` | Notes | Pomodoro | Media | Notifications | Dashboard |
| Productivity | `checklist` | `#FF9230` | Notes | Reminders | Tasks | Quotes | Dashboard |
| Simple | `sparkles` | `#0ea5e9` | Media | Day progress | Quotes | Calculator | **Date** |

Per-profile keys: `icon`, `colorHex`, four/eight widget slots, `twoRowsEnabled`,
`headerDisplay` (Dashboard | Date), `profileSwitcherDisplayStyle` (With text),
`showDividers`, `showWeather`, and independent header-icon toggles —
`showInfoIcon`, `showMirrorIcon`, `showLiveActivityIcon`, `showNewNoteIcon`,
`showSettingsIcon` — plus `launcherApps`, `actionApps`, `quickToggleSlots`.

**Widget types observed:** Quick toggles, Screen Time, Apps, Actions, Day progress,
Pomodoro, Events, Media, Bluetooth, Summary, Notes, Notifications, Quotes, Reminders,
Tasks, Calculator, Weather, Mirror.

**Quick toggle kinds:** `screenClean`, `darkMode`, `hideDesktopIcons`, `showHiddenFiles`,
`lockScreen`, `startScreenSaver`.

**Launcher/Actions are paginated sets** — `dashboardLauncherSetCount: 2`,
`dashboardActionSetCount: 2`, matching the "Set 1 of 3" / "Set 1 of 2" pagers in the
screenshots.

### 6.3 Live Activities — priority order is a stored array

```
["loading", "bluetooth", "appUpdates", "systemHUD", "media", "pomodoro", "event", "todo"]
```

Plus `liveActivityAnimation: spring` and `liveActivityTransition: scale`. So the collapsed
strip is a **priority queue with a user-reorderable order**, not a round-robin. Mira should
model it the same way: one array, one resolver picking the highest-priority active source.

### 6.4 Per-module expanded height is a real setting

`translationNotchExpandedHeight`, `dashboardTwoRowsNotchExpandedHeight`,
`notesNotchHeightLevelMigrationV1` — each module owns its height, some with a discrete
"height level". Confirms §1.1: height is per-module, not global.

### 6.5 How they solve the two hard problems

**Media on modern macOS** — they ship `mediaremote-adapter.pl` +
`MediaRemoteAdapter.framework` in Resources. This is **[mediaremote-adapter by Jonas van
den Berg, BSD 3-Clause](https://github.com/ungive/mediaremote-adapter)** — a Perl shim
that loads the private MediaRemote framework from an Apple-signed interpreter context, so
Now Playing data keeps working after Apple locked the framework down in macOS 15.4+.
It exposes `stream`, `get`, `send`, `seek`, `shuffle`, `repeat`, `speed`, `test`.

This is the whole answer to "how do they control Spotify, Apple Music, Plex, NetEase, VOX,
VLC, browsers and system audio through one API." **BSD-3 licensed, so Mira can adopt it
directly.** It requires `com.apple.security.cs.disable-library-validation` — which is in
their entitlements, and which Mira's local-install build already sets.

**AI Coding** — they don't poll. They ship
`claude-code-hook-with-socket.sh` and `cursor-agent-hook-with-socket.js` and have the user
install them as CLI hooks. The hook opens a Unix socket at
`/tmp/macnotch-aicoding-$(id -u).sock`, registers with `{"keep_alive":true,"session_id":…}`,
sends `{event_name:"PreToolUse", session_id, tool_name, tool_input}`, and for
`Shell|Bash|Execute|Write|Edit|MultiEdit|NotebookEdit` **blocks on a
`{"type":"permission_response","approved":bool}` reply with a 5 s timeout**, falling back
to the terminal prompt if the socket is absent. That's the entire Allow/Deny mechanism.

Mira already has `ClaudeCodeBridge` and a bidirectional MCP path, so this is a small
addition — but the *blocking hook with timeout-and-fallback* is the design worth copying.

### 6.6 Everything else the bundle gives away

- **`BluetoothService.md`** — they shipped their own internal engineering doc for the
  Bluetooth module in `Contents/Resources`. It specifies the full implementation:
  three-source battery lookup (BLE Battery Service `0x180F`/`0x2A19` → parsing
  `log show --predicate 'subsystem == "com.apple.bluetooth" AND eventMessage CONTAINS "Battery"'`
  for `CBPowerSource … Battery -90%` → IORegistry `AppleDeviceManagementHIDEventService`
  `BatteryPercent`), three-tier device typing (BLE Appearance `0x2A01` → name heuristics →
  Class of Device), fuzzy name matching across IOBluetooth/CoreBluetooth, and poll
  intervals (**2 s device status, 30 s BLE battery, 30 s throttled log parse**). This is a
  complete build guide for Mira's Bluetooth module — read it before writing a line.
- **Weather is video.** `WeatherSkyClearDay/ClearNight/Cloudy/Dawn/Dusk/Fog/Rain/Snow/Storm.mp4`
  — nine looping mp4s behind the weather widget. That's the entire reason it looks
  expensive.
- **Five completion sounds** `sound-1..5.mp3` for Pomodoro.
- **App Intents**: `MacNotchFocusFilter` (this is how Focus integration works — a Focus
  Filter intent, not polling), `ShowCustomAlertIntent`, `DashboardProfileQuery`. Shortcuts
  support for free.
- **`useDemoData`** pref — how the marketing screenshots were made.
- **Referral system** and `usageSharingCountersData` (`{snapByZone, notchExpands, moduleOpens, appSessions}`).
- **Info.plist**: `LSUIElement = true`, `LSMinimumSystemVersion = 14.0`, built against the
  macOS 27 SDK, Sparkle feed `https://macnotch.io/appcast.xml`, URL scheme `macnotch://`,
  Contacts usage ("sender photos in message notifications"), Speech Recognition + Microphone
  ("reply to notifications using your voice").
- **Entitlements**: not sandboxed; `automation.apple-events`, `allow-jit`,
  `allow-unsigned-executable-memory`, `disable-library-validation`, `network.server`
  (the AI Coding socket), camera, audio-input, calendars, location.

### 6.7 The window frame snaps; the content animates

Polled the layer-26 window every 3 ms across many open/close cycles. Across a 150 s trace
the only values ever observed were the two endpoints:

```
   0.022  x=256.0  w=1215.00  h=370.00
  93.634  x=399.0  w= 930.00  h=112.00
```

**Zero intermediate frames**, at a sampling rate that would have caught ~100 of them in a
300 ms animation. So the container window is resized **discretely** and every bit of the
visible motion happens *inside* it in SwiftUI.

That is the single most important implementation directive in this document:

> Grow the window to the final frame first (or keep it oversized), then animate the content
> within it. Never animate `NSWindow.setFrame` — that is what makes a notch feel laggy and
> tear against the menu bar. On collapse, animate the content closed and only shrink the
> frame after the animation completes.

Related: `liveActivityAnimation: spring` / `liveActivityTransition: scale` give the motion
vocabulary — spring, scale-in.

**Hover-open has a dwell threshold, and open persists while the pointer is inside.** The
notch stayed open for 93 s of the trace with the cursor parked on it, with no auto-close
timer. Two separate synthetic-input observations are worth copying:

- Warping the cursor straight to the notch usually did **not** open it; a multi-step
  incremental approach did. MacNotch is gating on genuine mouse-moved events, not merely
  "pointer is inside rect" — which is why it doesn't fire when you fling the cursor past
  the top of the screen.
- Expansion twice occurred *after* a 7 s observation window closed, so the dwell threshold
  is real and interacts with the Interaction pane's *Only when hovering* and snooze
  duration settings.

### 6.8 Still unmeasured

Not blocking, listed for completeness:

- **Animation duration and easing constants.** Not obtainable from window frames (see
  §6.7) — they live in the SwiftUI content. Tune by eye against a screen recording.
- **Per-module expanded heights.** Requires clicking through the module dock, which the
  computer-use layer refuses (MacNotch is `LSUIElement` and is not resolvable as a
  grantable app; `showMacNotchIconInDock = 1` does not change this). Derive from content
  instead — Phase 0 makes height per-module by construction.
- **Snap Zones and Drop Actions overlay geometry.** Separate window states, same
  constraint.

---

## Appendix — evidence

- Site copy: `macnotch.io/assets/index-lFRQbvHY.js` (i18n bundle, English keys).
- `demo-00.mp4` (16s) — Snap Zones: drag window up → 10 tiles in notch, live window
  thumbnail follows cursor, hovered tile highlights, release snaps. Header reads
  `Snap Window` / `Halves, quarters & thirds`.
- `demo-01.mp4` (140s) — module tour: Actions, Dashboard (Simple profile), Todo,
  Translation, Code hosting pipelines, System Analytics. Module dock visible below
  slab throughout; 5 dock pills in this config.
- `demo-02.mp4` (68s) — Shelf (6 items, Move/trash/info header), Drop Actions grid
  (AirDrop/iCloud/Shelf/Open with/Convert/Zip), Settings → Drop Actions with live
  notch preview.
- `demo-03.mp4` (16s) — Event Reminder overlay with Join Microsoft Teams, Snooze,
  Dismiss, Dismiss All, elapsed counter.
