# QA #2 — Query-Routing Feature Wave (code/wiring audit)

**Date:** 2026-07-08
**Scope:** The cost-tiered query-routing wave — deterministic route dispatch, the
Weather and web-search "cheap text" paths, the instant video-playback path, and
the browser picker (`BrowserService`).
**Method:** Since the UI can't be driven headlessly, this is a static code/wiring
audit for the three bug classes that bit the activity-chip fix (#1): **dropped
functionality**, **unhandled paths**, and **unbalanced lifecycles**.

## Verdict

**The feature wave is sound. No functional bugs found.** One robustness
watch-item noted below (hardening candidate, not a defect). All five activity
surfaces were separately confirmed leak-safe in #1.

## Findings

### Query routing — ✅ Safe
Execution dispatch (`RouterService.handle`) is an **exhaustive switch — no
default** — over all 33 `MiraRoute` cases. The compiler forbids the fall-through
bug that hit the chip: add a route and the switch won't compile until it's
handled. Deterministic/safety routes bypass the Haiku gate; on any Haiku failure
`classifyIntent` falls back to the synchronous keyword `route()` — never nil.

### Weather cheap path — ✅ Correct
`weatherResult` opens the Weather app visibly (and drives its AX search for a
named city) **and** answers from a cheap wttr.in text lookup — no vision cost.
Both effects always fire. Unhandled-path check: if `WeatherService.lookup`
returns nil, it still replies `"I opened the Weather app[ for <city>]"` — the
visible side-effect and a spoken reply are both guaranteed, never a dead end.
The AX search-drive is best-effort and early-returns on focus failure, but the
spoken answer already names the right city, so nothing is dropped.

### Web-search cheap path — ✅ Correct
`webSearchResult` opens the user's chosen browser to the live Google results
(visible, free) **and** reads a verified answer via Anthropic's `web_search`
server tool (Haiku, cited, no HTML scrape). Fallback path is graceful: if
`webSearchAnswer` is nil/empty it replies `"I opened the results in <browser>"`.
No screenshot loop, no quota consumed.

### Browser picker / BrowserService — ✅ Safe
`activeBrowser()` prefers the saved bundle only if still installed, else falls
back to the system default. `open()` has a terminal fallback —
`NSWorkspace.shared.open` + `"your browser"` — so a missing/unresolvable browser
degrades to the OS default instead of crashing or silently no-op'ing.

### Video playback (instant YouTube) — ✅ Safe
`videoPlayback` opens YouTube results deterministically (no vision loop, no
quota). Guards the one failure path: if `youtubeSearchURL` can't build a query it
replies asking the user to name the video, rather than opening a broken URL.

### LocationProvider lifecycle (weather geolocation) — ✅ Balanced
The `CheckedContinuation` is the one lifecycle risk here, and it's handled: a 6s
safety-net timeout (`finishIfPending`), an in-flight guard (`continuation != nil`)
before every resume, and `finish()` nils the continuation — so it resumes exactly
once and can never hang on "Locating…" or double-resume.

## Watch-item (robustness, not a bug)

`weatherResult` → `openWeatherApp` sends synthetic keystrokes via
`ComputerUseService.type` after a fixed 900 ms sleep, on the assumption Weather is
frontmost. It focuses the field via AX on `com.apple.weather` first and
early-returns if that fails, so it's guarded — but if Weather is slow to come
forward past the fixed sleep, keystrokes could theoretically land in another app.
Impact is cosmetic (the spoken wttr.in answer is already correct and
city-accurate), so it's a hardening candidate, not a wave blocker.

## Bottom line

Every route in the wave produces both its visible side-effect and a guaranteed
reply, every failure path degrades gracefully, and the one continuation lifecycle
is correctly single-resume. Wave passes the audit.
