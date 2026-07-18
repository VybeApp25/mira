# Mira API Contracts

This directory is the single source of truth for the request/response shapes Mira's clients (macOS Swift today, a future Windows client) exchange with the shared Supabase backend. It exists to stop Swift and C# types being hand-duplicated from reading each other's source — see [docs/windows/WINDOWS_ARCHITECTURE.md §5](../../docs/windows/WINDOWS_ARCHITECTURE.md) for the rationale.

## What's here

- `common/` — shapes shared across multiple functions (the generic error envelope).
- `auth/` — Supabase's own hosted GoTrue auth API (not a Mira Edge Function, but a contract both clients depend on identically).
- `tables/` — Postgres row shapes read directly via PostgREST (currently just `profiles`, the one table the client reads directly rather than through an Edge Function).
- `edge-functions/` — one schema file per client-facing Supabase Edge Function in `supabase/functions/`.

Every schema file was derived by **directly reading the corresponding `supabase/functions/*/index.ts` source** (or, for `auth/`, `Mira/Services/SupabaseService.swift`'s existing `Codable` structs, which already decode Supabase GoTrue's response), not inferred from a spec or written speculatively. Each file's `description` cites the exact source file it came from.

## What's deliberately NOT modeled here

- **Transparent-proxy passthrough bodies.** `anthropic-proxy` and `openai-proxy` only validate/constrain a couple of fields (`model`, `max_tokens`) and forward everything else to the provider unchanged — this repo does not attempt to redefine the full Anthropic Messages API or OpenAI Chat Completions API surface. If you need those, they're each vendor's own published contract, not Mira's.
- **`assemblyai-proxy` and `composio-proxy` per-path bodies.** Both are path-forwarding proxies over an entire third-party REST API; only the proxy's own routing/auth constraints and error shapes are modeled.
- **`stripe-webhook`.** It's not called by any client — Stripe calls it directly, authenticated by HMAC signature, not a Supabase JWT. Out of scope for client-contract purposes.
- **`spend-alarm`.** Internal, `pg_cron`-triggered only, never called by a client.
- **`render-onboarding-marin`.** Confirmed in Phase 0 as a maintainer-only build tool, not a client-facing endpoint.

## Known asymmetries preserved as-is, not "fixed"

A few functions have inconsistent auth/quota patterns compared to their siblings (e.g. `mint-assemblyai-token` doesn't check a voice quota the way `mint-realtime-token` does; `openai-tts-narration` doesn't call `requireEntitlement`/`checkQuota` the way most other proxies do). These are noted in the relevant schema's `description` rather than silently normalized — the contract should describe what the server *actually does* today, not what it arguably should do. If those asymmetries get fixed server-side, update the schema in the same change.

## Regenerating client types

See [`../codegen/README.md`](../codegen/README.md) for how to turn these schemas into Swift and C# types.

## Adding a new contract

1. Read the actual Edge Function source (or table/migration) — never write a schema from the product description or by guessing at a shape.
2. Follow the existing file's structure: a `$defs` block with one entry per request/response/error shape, a top-level `description` citing the source file, and per-field `description`s for anything non-obvious (validation rules, defaults, known quirks).
3. Reference `common/error-response.schema.json` via `$ref` + `allOf` for error shapes rather than redefining the base envelope each time.
4. Regenerate (see codegen README) and spot-check the output before committing.
