# Security and Privacy — Phase 0 Findings

This document covers what this audit confirmed about Mira's current secrets/auth/entitlement architecture, what that implies for a Windows client, and one concrete finding that needs remediation regardless of the Windows work. All claims are backed by direct source reading — see [REPOSITORY_EVIDENCE.md](REPOSITORY_EVIDENCE.md) for full file/line citations. No secret values are reproduced in this document.

---

## 1. Current secrets architecture (confirmed)

The backend was already redesigned around a "no provider secrets in the client" principle, and that redesign is **live in the current source**, not aspirational:

- `Mira/Services/MiraBackend.swift`: `static let useProxy = true`. Every Anthropic, OpenAI (chat + TTS), and AssemblyAI call the client makes is routed through a Supabase Edge Function rather than calling the provider directly.
- `supabase/functions/_shared/auth.ts`: `requireUser(req)` verifies the caller's Supabase JWT via a service-role client (`admin.auth.getUser(jwt)`) and loads their plan from `profiles` — **identity is never trusted from anything the client sends**, only from the verified token.
- Per-plan daily token budgets (`free: 100,000`, `pro: 2,000,000`, `ultra: 10,000,000`, input+output combined) are enforced server-side in `checkQuota`/`meter` against the `usage` table — a stolen or tampered client session cannot exceed its plan's budget.
- Realtime voice has a **separate** server-side cap (`checkVoiceQuota`/`daily_voice_caps(plan)`/`voice_usage` table) because audio minutes aren't token-metered the same way — this closed a previously-uncapped abuse vector (confirmed by the migration's own header comment describing the prior state as exploitable).
- `Mira/Services/EntitlementService.swift` is explicitly documented, in both the code and `docs/architecture/backend_secrets_proxy.md`, as **client-side UX only** — `profiles.plan` (server-side, Stripe-webhook-updated) is the actual source of truth.

**What this audit could not confirm:** the current contents of `Mira/Config/AppSecrets.swift`. That file is listed in `.gitignore` and is genuinely absent from this checkout, so this audit cannot state definitively whether any provider key is still compiled into the shipped macOS binary today. The live `useProxy = true` flag and the surrounding proxy infrastructure are consistent with the migration having completed, but this is inferred from the surrounding code, not confirmed by reading the file itself. **Recommendation: before starting Windows client work, directly verify (via `strings` on a built macOS binary, per the same technique `docs/architecture/backend_secrets_proxy.md` describes using) that no provider secret ships client-side today.**

---

## 2. A concrete finding: a committed plaintext secret

`supabase/migrations/20260626120000_device_lock_and_spend_alarm.sql` contains a `pg_cron` job definition that posts to the `spend-alarm` Edge Function with a hardcoded `x-cron-secret` header value, **committed in cleartext directly in the SQL migration file**. This is a real secret value checked into version control, not a placeholder or example.

**Why this matters:** anyone with read access to this repository (or its git history, even after a later edit) has this value. If `CRON_SECRET` is still the live value guarding the `spend-alarm` function, that function's trigger can be invoked by anyone who has seen this file or this repo's history.

**Recommended remediation (independent of the Windows port, should happen regardless):**
1. Rotate the `CRON_SECRET` Supabase secret.
2. Update the `pg_cron` job definition to reference the new value.
3. Going forward, do not commit secret values directly into migration SQL — reference `current_setting()`/a vault entry, or accept that any value written into a migration file must be treated as disclosed the moment it's committed, and rotate immediately after that commit if it wasn't meant to be public.

This finding is not reproduced with its actual value anywhere in this audit's documents, per this task's explicit instruction not to expose secret values.

### Remediation runbook — step by step

**Prerequisite:** the Supabase CLI, logged into the project this repo deploys to (`supabase login`, then `supabase link --project-ref <ref>` if not already linked). This audit's environment has neither the CLI installed nor a project link, so these steps need to be run by whoever holds that access — they are not run as part of this repository change.

1. **Generate a new secret value locally** (don't reuse or lightly modify the old one — treat it as fully compromised):
   ```bash
   openssl rand -hex 32
   ```
   Keep the output somewhere safe (a password manager), not in a shell history file or an unencrypted note.

2. **Set the new secret on the Supabase project:**
   ```bash
   supabase secrets set CRON_SECRET=<the value from step 1>
   ```

3. **Update the `pg_cron` job to send the new value.** The job lives in `supabase/migrations/20260626120000_device_lock_and_spend_alarm.sql` and was created with `cron.schedule('mira-spend-alarm', ...)`. `pg_cron` jobs aren't re-applied by re-running old migrations — you update the *live* job directly via SQL (run this in the Supabase SQL editor or `psql` against the project, substituting the new value):
   ```sql
   select cron.unschedule('mira-spend-alarm');
   select cron.schedule(
     'mira-spend-alarm',
     '0 * * * *',
     $cron$
       select net.http_post(
         url     := 'https://rdbljrbjsmbfqwwpwwvn.supabase.co/functions/v1/spend-alarm',
         body    := '{}',
         headers := '{"Content-Type":"application/json","x-cron-secret":"<the new value from step 1>"}'::jsonb
       );
     $cron$
   );
   ```

4. **Confirm the `spend-alarm` function actually validates `x-cron-secret` against `Deno.env.get("CRON_SECRET")`** — this audit did not open `supabase/functions/spend-alarm/index.ts` to verify the check exists and is enforced (only the cron-job side, in the migration file, was read). Verify this before considering the rotation complete; if the function doesn't check the header at all, the secret was cosmetic and the real fix is adding the check.

5. **Write a new migration file recording that this rotation happened** (a comment is enough — `-- Rotated CRON_SECRET on <date>, prior value revoked, see docs/windows/SECURITY_AND_PRIVACY.md`), so the history explains the gap for future readers rather than looking like an unexplained schedule change. Do **not** put the new secret value in that file — that would repeat the original mistake.

6. **Verify the old value no longer works** by manually invoking the function with it (expect a rejection) — this confirms the rotation actually took effect rather than the new secret being set but the old cron job still holding the stale header.

None of these six steps were executed as part of this session — they require Supabase project credentials this environment doesn't have. This runbook exists so they can be run in a few minutes by whoever does have access, without having to re-derive the procedure from the migration file.

---

## 3. Entitlements and subscription enforcement

Confirmed layering, relevant to a Windows client:

- `profiles.plan` (`free`/`pro`/`ultra`) is written only by the `stripe-webhook` Edge Function (service role, RLS-bypassing) in response to verified Stripe events (`checkout.session.completed`, `customer.subscription.updated/deleted`). No client, macOS or Windows, can write this column directly — RLS on `profiles` grants only `select` to the owning user (`supabase/migrations/20260614120000_secrets_proxy.sql`).
- `EntitlementService` on the client is a cache/UX layer that periodically re-fetches `profiles.plan` (on app-activation, and via a ~2-minute poll after a checkout/portal action) — a Windows client needs the equivalent poll-on-window-activation behavior to avoid a stale plan display, but has no security responsibility here since the server enforces the actual limits.
- Task-run and voice quotas are similarly server-side and JWT-derived (`consume_task_run`, `checkVoiceQuota`) — a Windows client cannot raise its own quota by any client-side manipulation, by design.

**Windows-specific implication:** none of this needs to change. A Windows client that authenticates via the same Supabase auth endpoints and attaches the same JWT header pattern inherits all of this enforcement for free. The risk to watch for is a Windows-specific *client bug* that trusts a locally-cached plan value for a security decision rather than treating it as UX-only — the macOS code already gets this right (confirmed: `EntitlementService.can(_:)` is never referenced from server-authorization code, only from UI gating), and the Windows port should preserve that separation.

---

## 4. Authentication and device-lock mechanism

- `SupabaseService.swift` implements email/password, native Sign-in-with-Apple, and a **browser-based Apple OAuth flow** (`mira://auth-callback`) — the browser flow exists specifically because native Sign-in-with-Apple's entitlement isn't available to a Developer-ID (non-App-Store) distribution. **This constraint is Apple-specific and does not apply to Windows** — a Windows client has no Sign-in-with-Apple parity concern to solve, though it should decide independently whether to offer Apple/Google/Microsoft sign-in via the same Supabase OAuth provider mechanism.
- Session tokens are persisted in `UserDefaults` (a plist-backed store), not Keychain — this is a **macOS design choice this audit does not recommend copying uncritically**. A Windows equivalent (registry or a plain settings file) has weaker at-rest protection than DPAPI-backed storage; recommend the Windows client store the session token via `Windows.Security.Credentials.PasswordVault` or DPAPI (`ProtectedData.Protect`), which is *more* protected than the current macOS mechanism, not less — worth raising with the user as a deliberate improvement rather than parity-for-parity's-sake.
- `DeviceFingerprintService.swift` computes SHA-256(IOKit hardware serial + a Keychain-persisted random UUID) to enforce "one free account per physical device" (`profiles.device_id_hash`, partial unique index, free-tier only). A Windows equivalent needs: (a) a stable hardware identifier (WMI `Win32_ComputerSystemProduct.UUID` is the closest analog, though it is reset by some virtualization/reimaging scenarios differently than a Mac's IOPlatformSerialNumber), and (b) DPAPI or Credential Manager for the persisted random component. This can reuse the existing `check-device`/`register-device` Edge Functions and `device_id_hash` column unchanged — only the client-side hash computation needs a Windows-native implementation that the server treats as an opaque string either way.

---

## 5. App sandboxing / permission model — no direct Windows analog

Confirmed: `Mira.entitlements` contains no `com.apple.security.app-sandbox` key — **the macOS app is not sandboxed.** This is what allows `MiraToolService`'s unrestricted shell/AppleScript tool calls (`run_shell_command`, `run_apple_script`, `run_in_terminal`) to function at all; under the App Sandbox these would be blocked outright.

Windows has no direct equivalent of the macOS App Sandbox *or* its TCC (TCC.db) permission-consent database (the system that gates microphone/screen-recording/accessibility/calendar access with a persistent per-app grant the user can review in System Settings). This has two implications worth surfacing to the user explicitly, not silently deciding:

1. **A Windows Mira running Computer-Use/actuation features by default has fewer OS-level guardrails than the macOS version does today** — there's no equivalent "Accessibility permission" gate the user grants once and can revoke; UI Automation access on Windows is generally available to any process at the same integrity level, with much coarser (or no) consent flow for most operations. This is a real behavior difference, not just an implementation detail — it changes the trust model users should be told about, since a compromised Windows Mira process could have a lower bar to clear for desktop actuation than a compromised macOS one does.
2. Screen capture on Windows via `Windows.Graphics.Capture` does have its own consent UI (a picker dialog for which window/monitor to share), which is *more* visible per-use than macOS's grant-once-then-invisible Screen Recording permission — worth deciding deliberately whether to lean into that as a trust-building UX moment rather than trying to minimize it to match the Mac experience.

Recommend this tradeoff be discussed explicitly with the user before Phase 1 implementation, rather than assumed.

---

## 6. Telemetry and privacy-sensitive data flows (partial coverage)

- `PostHogService` is referenced throughout the client (`auth_sign_in`, `auth_sign_up`, `auth_sign_out` events confirmed in `SupabaseService.swift`/`AccountService.swift`) but was not deep-audited in this pass — **flagged for a follow-up read** before Windows client telemetry is wired up, to confirm exactly what properties are captured and whether any PII beyond email/user-id crosses that boundary.
- `MemoryStore` and `UserKnowledgeStore` are both confirmed **local-only** with zero network calls in their own files — this is a meaningful privacy property (a user's remembered facts and imported cross-assistant profile never leave the device today) that a Windows port should preserve rather than "improve" by adding sync without an explicit decision to do so.
- `docs/legal/PRIVACY.md` and `docs/legal/TERMS.md` exist in the repo but were not read as part of this security pass — cross-check them against the confirmed data flows above before any public Windows release, since a legal document making claims about data handling should match what the code (Windows or Mac) actually does.

---

## 7. Summary — what must remain server-side for Windows, unconditionally

Regardless of language/framework choice, the Windows client must never embed:
- Anthropic, OpenAI, AssemblyAI, Composio, or Miso API keys.
- The Supabase **service-role** key (only ever used inside Edge Functions today, confirmed).
- The Stripe **secret** key or webhook signing secret.
- The `CRON_SECRET` value referenced in §2 (rotate it regardless of Windows work).

The Windows client, like the current macOS client, should carry only: the Supabase project URL, the Supabase **anon** key (public by design), and a PostHog project key (public by design) — mirroring `AppSecrets`'s intended post-migration contents per `docs/architecture/backend_secrets_proxy.md`.
