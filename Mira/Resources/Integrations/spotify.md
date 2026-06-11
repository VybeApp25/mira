# Spotify
tool: control_spotify (built-in Realtime tool)

## When to use
User says: play, pause, skip, next, previous, queue, what's playing, shuffle, volume, Spotify.

## control_spotify actions
- `play_song` — search + play by song name: `control_spotify(action:"play_song", song:"<query>")`
- `play` / `pause` / `next` / `previous` — playback control
- `get_state` — what's currently playing
- `set_volume` — 0–100
- `set_shuffle` — true/false
- `queue_song` — add to queue

## Canonical patterns

### "Play <artist/song>"
`open_application("Spotify")` if Spotify not running, then `control_spotify(action:"play_song", song:"<query>")`.

### "Skip / next"
`control_spotify(action:"next")`.

### "What's playing?"
`control_spotify(action:"get_state")` → say track + artist naturally.

### "Queue up <song>"
`control_spotify(action:"queue_song", song:"<query>")`.

## Constraints
- Playback mutation requires Spotify Premium.
- Always open Spotify first if it's not running.
- No confirmation needed for playback controls — they're reversible.
