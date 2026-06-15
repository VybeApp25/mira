# Backend Secrets Proxy — Design

**Status: DESIGN (2026-06-14).** Addresses release blocker #1 ([release audit](../../)): live *secret* API keys (Anthropic, OpenAI, Composio, AssemblyAI, Miso) are compiled into the client and extractable from the shipped binary via `strings`. They must move behind a per-user-authenticated backend before any public distribution.

> **Update (2026-06-15):** Composio is now done too. The Node agent sidecar points the Composio SDK's `baseURL` at a new **`composio-proxy`** edge function (transparent reverse proxy → `backend.composio.dev`, JWT-verified, server-held `x-api-key` injected) and authorizes with the user's JWT via the SDK's `defaultHeaders`. The JWT is plumbed through every sidecar Composio call (`/agent/run`, `/agent/confirm`, `/connect`, `/connections`, `/connections/status`). `AppSecrets.composioAPIKey` is now empty; the key lives only as the `COMPOSIO_API_KEY` Supabase secret (same value, **not** rotated). Verified end-to-end (HTTP 200 from Composio via the proxy with a throwaway user) and confirmed absent from the built binary + bundled `server.js` via `strings`. No rotation-target provider secret remains in the client; only the empty/optional slots (OpenRouter, Miso, Stripe).

## What already exists (reuse, don't rebuild)
- **Per-user auth:** `SupabaseService` does real email/password `signIn`/`signUp` → `SupabaseSession.accessToken` (a per-user JWT), with refresh + persistence. The identity layer is done.
- **Plans/entitlements:** `EntitlementService` models `free / pro / ultra` + an `Entitlement` enum (`runAgents`, `useVoiceMode`, `useScreenGuidance`, …) + `can(_:)`. Today it's **client-side only** (bypassable) — the proxy makes it server-enforced.
- **Edge-function pattern:** `supabase/functions/mint-realtime-token/index.ts` (Deno) already mints an OpenAI Realtime ephemeral token. **But** it (a) has no auth/entitlement check, (b) the client falls back to the raw `AppSecrets.openAIKey` on failure, (c) is called with the anon key, not a user JWT. Half-built — harden and generalize it.
- **Call sites:** ~25 `AppSecrets.*` references. Anthropic in ~10 (`ClaudeService`, `MiraToolService` ×4, `ElementLocationDetector`, `BackgroundScheduler` ×2, `CronScheduler`, `ExternalTriggerRunner`, `AgentProcessManager`, `OutputDetailView`); OpenAI in 3 (`OpenAIService`, `RealtimeVoiceService`, `IslandChatView`); AssemblyAI ×2; Composio ×1 (Node sidecar); Miso ×1.

## Principles
1. **Provider secrets live only in Supabase function secrets** (`Deno.env.get`). The client ships **zero** provider secrets — only public keys (`supabaseURL`, `supabaseAnonKey`, `postHogKey/Host`).
2. **Every call carries the user's Supabase JWT.** The server is the source of truth for identity, plan, and quota; the client `EntitlementService` becomes UX-only.
3. **Two transport patterns:**
   - HTTP request/response (incl. SSE streaming) → **reverse-proxy** edge function.
   - Realtime/streaming sockets → **short-lived ephemeral-token minting**; client connects directly to the provider.

## Pattern A — Reverse proxy (Anthropic, OpenAI chat, AssemblyAI batch, Miso TTS)
The edge function receives the **same body** the client used to send to the provider, then: verify JWT → check entitlement + quota → inject the real key server-side → forward → stream the response back unchanged.
- Client change is minimal: swap the base URL, drop the `x-api-key`/`Authorization: Bearer <provider key>` header, add `Authorization: Bearer <supabase JWT>`. **Request bodies are untouched** (the proxy is transparent), so tool-use, streaming, vision, etc. work as-is.
- `anthropic-proxy`: forwards to `api.anthropic.com/v1/messages`; passes `stream:true` SSE straight through. Enforces a **model allowlist** + per-plan `max_tokens` cap. Meters `usage.input_tokens`/`output_tokens` from the response into the `usage` table.
- `openai-proxy`, `assemblyai-proxy` (batch), `miso-tts-proxy`: same shape.

## Pattern B — Ephemeral token (OpenAI Realtime, AssemblyAI streaming)
You can't cheaply proxy a realtime audio socket; mint a short-lived token and let the client connect directly (the provider-blessed pattern).
- `mint-realtime-token` (exists): **harden** — require a verified JWT, gate on `useVoiceMode` + a voice-minutes budget, **remove the client's raw-key fallback** (`RealtimeVoiceService.swift:279`), return `402`/`429` on failure instead of silently using the embedded key.
- `mint-assemblyai-token` (new): AssemblyAI temporary streaming token, gated likewise.

## Shared middleware — `supabase/functions/_shared/auth.ts`
- `requireUser(req) → { userId, plan }` — Supabase verifies the JWT signature (`verify_jwt`); read `sub`; load `plan` from `profiles`. Never trust client-sent identity.
- `requireEntitlement(plan, entitlement)` → `402 upgrade_required` if insufficient.
- `checkAndMeter(userId, provider, estCost)` → atomic usage increment vs the plan budget; `429 quota_exceeded` if over.
- Standard errors: `401` unauthenticated · `402` upgrade · `429` quota · `5xx` provider passthrough.

## Database (Supabase Postgres, RLS on)
- `profiles(user_id PK, plan text default 'free', stripe_customer_id, updated_at)` — **source of truth for plan**; `EntitlementService` syncs *from* here. A Stripe webhook updates it (shared with payments work).
- `usage(user_id, provider, window_start, requests int, input_tokens bigint, output_tokens bigint, UNIQUE(user_id,provider,window_start))` — quota + metering; incremented atomically via an `rpc`/upsert.
- (Optional) `request_log` for cost/audit — **never store message content** (privacy).
- RLS: a user reads only their own `profiles`/`usage`; only the service role (edge functions) writes.

## Client changes (Swift)
- New `MiraBackend` helper: `base = "\(supabaseURL)/functions/v1"`; `authedRequest(path)` attaches `Bearer session.accessToken`, refreshing via `SupabaseService` when expired.
- Route the call sites above through `MiraBackend` (URL + auth header only; bodies unchanged).
- `AppSecrets`: **delete** anthropic / openai / composio / assemblyai / miso / openrouter keys. Keep `supabaseURL`, `supabaseAnonKey`, `postHogKey/Host`.
- New error UX: `401` → re-auth sheet · `402` → paywall (via `EntitlementService`) · `429` → "daily limit reached — upgrade or try later."
- **Sign-in becomes required before any AI feature** (today the anon key works without a user). Fold auth into onboarding (`OnboardingView`).

## Composio / local Node sidecar (`server.js` / `AgentService/src/`)
Agents run via a local Node sidecar (`http://127.0.0.1:4242`) that receives `COMPOSIO_API_KEY` + `ANTHROPIC_API_KEY` via env (`AgentProcessManager.swift:65-66`). It exposes `/agent/run`, `/agent/confirm`, `/connect/:app`, `/connections/status`, `/connections`, `/disconnect/:app`, all keyed by a `userId` = **Composio entity**. `agent.ts` uses `@composio/client` v3: `connectedAccounts.link(userId, authConfigId)`, `connectedAccounts.list({ userIds:[userId] })`, `authConfigs.list/create`.

**DONE 2026-06-14 — per-user connected accounts.** The sidecar already threads `userId` as the entity everywhere; the bug was the client sending the constant `"default"` for **every** user (`AgentService.userId`), so all users shared one Composio entity and could see each other's connections. Fixed: `AgentService.userId` now = the signed-in **Supabase `session.userId`** (signed-out/dev → manual override → `"default"`). Connected accounts are now isolated per user. (Existing single-user connections under the old `"default"` entity must be reconnected.)

**STILL OPEN — Composio key removal (larger, two-part, separate effort):**
1. **Connection management** (`/connect`, `/connections`, `/disconnect`) → portable to a `composio-broker` edge function that holds `COMPOSIO_API_KEY`, verifies the JWT, and derives entity = `user_id` **server-side** (so a local client can't spoof another user's entity). It's a faithful port of the three `agent.ts` functions to a Deno function using `npm:@composio/client`. NOT yet built — needs deploy + a real OAuth round-trip to verify, so it wasn't shipped blind.
2. **Agent execution** (`/agent/run`, `/agent/confirm`) genuinely needs the local agent runtime (Anthropic loop + Composio tool calls + confirmation flow) — moving it server-side is a major lift. Interim: point the sidecar's own Anthropic calls at `anthropic-proxy` (pass the JWT instead of `claudeApiKey`), shrinking its key surface to just Composio.

**Honesty note:** the entity fix makes per-user isolation the *default*, but does not *enforce* it against a determined local attacker who extracts the still-embedded Composio key and supplies a forged entity. True enforcement requires #1 (server-derived entity + key off the client). Lower exposure than the web-distributed Anthropic/OpenAI keys (sidecar is local), but on the list.

## Cost & abuse controls (the whole point of server-side)
- Per-plan model allowlist; reject unknown models.
- Per-plan `max_tokens` hard cap (a stolen session can't drain the budget in one call).
- Per-user daily/monthly token budget enforced in `usage`.
- Global spend circuit-breaker + alerting (Supabase + provider dashboards).
- Request-size cap; reject oversized prompts/images.

## Rollout (incremental, low risk)
1. `profiles`/`usage` tables + `_shared/auth.ts` + `anthropic-proxy`. `supabase secrets set ANTHROPIC_API_KEY=…`. Deploy.
2. Behind a build flag, point the Anthropic call sites at the proxy; verify streaming + tool-use end-to-end (Anthropic first — most call sites, highest spend risk).
3. Repeat per provider: `openai-proxy`, harden `mint-realtime-token`, `mint-assemblyai-token` + `assemblyai-proxy`, `miso-tts-proxy`, Composio.
4. Make sign-in required; wire `401/402/429` UX.
5. **Delete keys from `AppSecrets`; ROTATE every previously-embedded key** (treat as compromised once any build shipped).
6. Load-test quota; run a stolen-JWT drill (revoke session → `401`).

## Payoff beyond security
The proxy authenticates per-user and reads `profiles.plan` — so it's **also** the enforcement point for the Stripe paywall (release blocker 🟡#7). `EntitlementService.plan` syncs from the same `profiles` table a Stripe webhook writes. Proxy + payments share infrastructure → **do the proxy first.**

## Effort estimate
~1–1.5 weeks: ½–1 day DB + `_shared/auth.ts` + `anthropic-proxy`; ½ day Anthropic client refactor; 2–3 days remaining providers + realtime hardening + auth-required UX; 1 day rotate/rollout/test. Realtime minting is already ~70% there.
