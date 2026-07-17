# Cursor Native-Feel: Detached Companion (HeyClicky-exact)

**Status:** BUILT + RUNTIME-VERIFIED on-device (2026-07-16). Real system cursor stays
native; blue companion trails offset beside it; tracking + click pass-through confirmed
via cliclick + `screencapture -C`.
**Implementation:** `Mira/Managers/MiraCursorManager.swift` only (`OverlayWindowManager`
rewritten; `CompanionCursorView`, `BlueCursorView` visuals). `CursorEventTap.swift`
deleted — no cursor tracking tap is used.
**Problem:** Mira's blue cursor felt laggy / "not native" vs HeyClicky.

---

## 1. Root cause (CORRECTED — the earlier version of this spec was wrong)

The previous diagnosis assumed HeyClicky's dedicated-thread `CGEventTap` was a *cursor
tracker* and prescribed an event-tap tracking rewrite. That was a misread. Verified
against HeyClicky's binary **and** its live on-screen behavior:

- HeyClicky's only taps are `escapeInterruptEventTap…` (from
  `CompanionManager+EscapeInterrupt.swift`) — the **Escape-key interrupt**, not the cursor.
- HeyClicky links **no** `CGDisplayHideCursor`/`CGDisplayShowCursor`, no CVDisplayLink,
  no CGS cursor SPI. It **never hides the system cursor.**
- On screen, HeyClicky shows the **real** system cursor (black arrow / I-beam, fully
  native) **plus** a blue cursor drawn as a **detached companion**, offset ~(+30…35,
  +25…26) pt down-right of the real pointer. (This is its `DetachedCursorClickCatcherView`.)

**So the real cause of Mira's lag:** Mira *hid* the real cursor and *pinned* a fake one to
the pointer tip. Any tracking latency then lands on the exact thing you aim/click with, so
it reads as lag. HeyClicky avoids this entirely by never being your cursor — you aim and
click with the real hardware cursor (which cannot lag), and the blue one is a companion
off to the side where latency reads as natural trailing.

## 2. Design (what shipped)

- **Never touch the system cursor.** No hide, no NSCursor replacement, no
  `SetsCursorInBackground` SPI. No invisible-cursor failure mode.
- **Click-through overlay** (`ignoresMouseEvents = true`), one borderless window per
  display at `cursorWindow` level. Every click is handled by the real cursor natively —
  nothing is caught or re-posted (no CGEventPostToPid on the normal path).
- **Detached companion**, drawn by SwiftUI `BlueCursorView` inside a layer-backed
  `NSHostingView`, positioned **imperatively** (`setFrameOrigin` in a
  disabled-action `CATransaction`) at `realPointer + companionOffset`. One tiny layer
  move per event — no `@Published`, no SwiftUI body re-eval on movement.
- **Position source:** passive `NSEvent` global + local mouse monitors (global for other
  apps, local for Mira's own windows). No event tap — matching HeyClicky. The companion's
  offset masks the monitor's slight latency.
- **State (cold path):** `@Published cursorState` still drives the arrow ↔
  thinking/stop/listening/speaking sub-views and live accent recolor — changes rarely.
- **Modal pause (Sparkle):** just order the companion out; nothing to "give back" since
  the real cursor was never taken.

## 3. Notable

- Result is **two cursors on screen** (real + companion) — the deliberate HeyClicky model,
  chosen intentionally.
- `companionOffset = (dx: +30, dy: −26)` (AppKit bottom-left coords → down-right on
  screen). Tunable in one place.
- Needs **no permissions** — no event tap, no screen-recording, no accessibility for the
  cursor itself.
- Bubble unchanged; still anchors to the real pointer while shown.

## 4. Prior dead-ends (so nobody re-tries them)

- **Custom `NSCursor` replacement from the background:** does not work. Tested on device —
  `NSCursor.set()` (via cursor-rect/`cursorUpdate` on a hit-test-nil overlay, and via a
  global-monitor re-assert) is overridden by whatever frontmost app owns the window under
  the pointer. A background `.accessory` app cannot own the system cursor without catching
  mouse events + forwarding clicks, which HeyClicky does NOT do for the base cursor.
- **Event-tap fake-cursor tracking (the previous rewrite):** even a dedicated-thread tap
  can't beat "don't be the cursor at all." Deleted.
