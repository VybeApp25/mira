# Onboarding narration (Marin voice)

Mira's onboarding is narrated line-by-line by `OnboardingNarrator`. The narrator
asks for the **`marin`** voice, but the `gpt-4o-mini-tts` `/audio/speech` endpoint
has no marin voice — marin is **Realtime-only**. So the live path 400s and falls
back to the flat macOS system voice.

Fix: we **pre-bake** every onboarding line in true Marin through the GA Realtime
API and bundle the mp3s. At runtime `OnboardingNarrator.bundledNarrationURL(for:)`
looks up `narration-<djb2(text + "marin")_base36>.mp3` in the app bundle and plays
it directly — authentic Marin, instant, offline, and working even before sign-in.

Bundled clips live in `Mira/Resources/OnboardingNarration/`.

## Pieces

- `supabase/functions/render-onboarding-marin/` — maintainer-only edge function.
  Opens a GA Realtime session (`gpt-realtime`, voice `marin`), reads one line
  verbatim, and returns the audio as WAV plus the model's own transcript (for QA).
  `OPENAI_API_KEY` stays inside Supabase; you authenticate with the **service-role
  key**, so ordinary signed-in clients can't call it.
- `tools/onboarding-narration/render.mjs` — the generator. Parses the
  `speakAndWait("…")` lines straight out of `NotchOnboardingManager.swift` (the
  single source of truth), hashes each to its filename, renders via the edge
  function, transcodes WAV→mp3 with ffmpeg, and QAs each clip's transcript against
  the source text.

## Usage

Deploy the function once (already deployed if clips exist):

```sh
supabase functions deploy render-onboarding-marin --no-verify-jwt
```

Then, from the repo root:

```sh
# Dry run — list every line and whether its clip is bundled (no network/key):
node tools/onboarding-narration/render.mjs --check

# Render only lines that aren't bundled yet:
SUPABASE_SERVICE_ROLE_KEY=... node tools/onboarding-narration/render.mjs --missing

# Re-render specific lines (1-based indices from --check, or hashes):
SUPABASE_SERVICE_ROLE_KEY=... node tools/onboarding-narration/render.mjs --only 4,6

# Re-render everything (fresh Marin takes for all lines):
SUPABASE_SERVICE_ROLE_KEY=... node tools/onboarding-narration/render.mjs --all
```

Get the service-role key from the Supabase dashboard (Project Settings → API) or
`supabase projects api-keys`. Each render is a fresh take, so re-run `--only` on
any line that sounds off.

## When you edit onboarding copy

If you change a `speakAndWait("…")` line in `NotchOnboardingManager.swift`, its
hash changes, so the old bundled clip no longer matches. Run `--check` to see
which clips are now missing, then `--missing` to render them, and delete the
now-orphaned old mp3. New Xcode resource references may need adding for brand-new
files.
