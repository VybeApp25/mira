# Stripe Go-Live Runbook

Everything in the app + backend is already wired. This is the ~1-hour admin
checklist to turn on real payments. Do the **Test mode** pass first (steps 1–7),
confirm an end-to-end upgrade works, then repeat steps 1–4 in **Live mode** and
flip the keys (step 8).

**Reference facts (already true in the code):**

| Thing | Value |
|---|---|
| Supabase project ref | `rdbljrbjsmbfqwwpwwvn` |
| Webhook URL | `https://rdbljrbjsmbfqwwpwwvn.supabase.co/functions/v1/stripe-webhook` |
| Plans | `free` (default) · `pro` $19.99/mo · `ultra` $49.99/mo |
| Source of truth | `profiles.plan` (the webhook writes it; the app reads it) |
| Deployed fns | `stripe-checkout`, `stripe-webhook` (verify_jwt=false), `stripe-portal` |

The 4 required secrets (+1 optional): `STRIPE_SECRET_KEY`, `STRIPE_PRICE_PRO`,
`STRIPE_PRICE_ULTRA`, `STRIPE_WEBHOOK_SECRET`, and optional
`STRIPE_PORTAL_RETURN_URL` (defaults to `https://miraapp.ai`).

> ⚠️ **Mode consistency is the #1 footgun.** Test price IDs only work with a
> test secret key; live price IDs only with a live secret key. Never mix. Each
> webhook endpoint (test vs live) has its **own** signing secret.

---

## 1. Create the Stripe account

1. Go to https://dashboard.stripe.com → sign up (or sign in).
2. Toggle **Test mode** ON (top-right) for the first pass.
3. Settings → Business: fill in enough to activate Checkout (test mode needs almost nothing).

## 2. Create the two products + recurring prices

Dashboard → **Product catalog** → **+ Add product** (do this twice):

| Product name | Price | Billing period |
|---|---|---|
| Mira Pro | $19.99 | Monthly (recurring) |
| Mira Ultra | $49.99 | Monthly (recurring) |

After saving each, click the **price** and copy its ID — it looks like
`price_1Q...`. You need **both**:

- Pro price ID → `STRIPE_PRICE_PRO`
- Ultra price ID → `STRIPE_PRICE_ULTRA`

## 3. Create the webhook endpoint

Dashboard → **Developers → Webhooks → + Add endpoint**:

- **Endpoint URL:** `https://rdbljrbjsmbfqwwpwwvn.supabase.co/functions/v1/stripe-webhook`
- **Events to send** (exactly these three — they're all the code handles):
  - `checkout.session.completed`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`
- Save, then click **Reveal** under "Signing secret" → copy the `whsec_...` value
  → that's `STRIPE_WEBHOOK_SECRET`.

## 4. Enable the Billing Customer Portal

Dashboard → **Settings → Billing → Customer portal** → **Activate**.
- Turn on "Allow customers to cancel subscriptions" (and update payment method).
- This is required or the in-app **Manage subscription** button (→ `stripe-portal`)
  returns an error.

## 5. Get your test secret key

Dashboard → **Developers → API keys** → copy the **Secret key** (`sk_test_...`)
→ that's `STRIPE_SECRET_KEY`.

## 6. Set the secrets in Supabase

From the repo root (`/Users/trevonbarbour/Mira`), with the Supabase CLI:

```bash
supabase secrets set \
  STRIPE_SECRET_KEY="sk_test_xxx" \
  STRIPE_PRICE_PRO="price_xxx_pro" \
  STRIPE_PRICE_ULTRA="price_xxx_ultra" \
  STRIPE_WEBHOOK_SECRET="whsec_xxx" \
  --project-ref rdbljrbjsmbfqwwpwwvn
```

(Optional, only if you don't want the post-checkout redirect to hit miraapp.ai:)
```bash
supabase secrets set STRIPE_PORTAL_RETURN_URL="https://yourdomain.com/account" \
  --project-ref rdbljrbjsmbfqwwpwwvn
```

Or set them in the dashboard: **Supabase → Project Settings → Edge Functions →
Secrets**. Secret changes take effect on the next function invocation — **no
redeploy needed**. (If you want to be certain, `supabase functions deploy
stripe-checkout stripe-webhook stripe-portal`.)

Verify they're set:
```bash
supabase secrets list --project-ref rdbljrbjsmbfqwwpwwvn
```

## 7. Test the full loop (test mode)

1. Sign in to Mira (the app must have a signed-in Supabase user — checkout uses
   the JWT).
2. Settings → Account → **Upgrade**, or hit a gated feature (Agents) → **Upgrade to Pro**.
3. Browser opens Stripe Checkout. Pay with the test card:
   - Number `4242 4242 4242 4242`, any future expiry, any CVC, any ZIP.
4. Complete payment. Back in the app, within ~2 min (or instantly on next app
   focus) the plan should flip to **Pro** — `EntitlementService` polls + refreshes
   on activation.
5. Confirm server-side:
   ```bash
   # in Supabase SQL editor
   select user_id, plan, stripe_customer_id, stripe_subscription_id
   from profiles order by updated_at desc limit 5;
   ```
   The row should show `plan='pro'` with a `stripe_customer_id` (`cus_...`) and
   `stripe_subscription_id` (`sub_...`).
6. Test **Manage subscription** (Settings → Account → Manage) → Billing Portal
   opens → cancel → on return the plan should revert to **free** (webhook
   `customer.subscription.deleted` → poll picks it up).
7. Check **Developers → Webhooks → [your endpoint] → events**: all deliveries
   should be `200`. A `400 Invalid signature` means `STRIPE_WEBHOOK_SECRET` is
   wrong/mismatched; a `400 no_subscription` from the portal means the customer
   had no active sub.

## 8. Switch to Live mode

Once the test loop is green:

1. Toggle **Test mode OFF** in the Stripe dashboard.
2. **Repeat steps 2–5 in live mode** (live products/prices, a *new* live webhook
   endpoint with its own `whsec_...`, live `sk_live_...` key). Live price IDs and
   the live secret key are all different from test.
3. Re-run the step-6 `supabase secrets set` with the **live** values (same
   secret names, overwriting test values).
4. Do **one real card** end-to-end (you can refund yourself afterward in the
   dashboard) to confirm live works.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Checkout opens but errors immediately | `STRIPE_PRICE_PRO/ULTRA` missing or wrong mode (test ID + live key, or vice-versa). |
| Paid but plan never updates in app | Webhook not delivering — check Developers→Webhooks events. `400` = wrong `STRIPE_WEBHOOK_SECRET`; no events = wrong endpoint URL or events not subscribed. |
| Webhook 400 "Invalid signature" | `STRIPE_WEBHOOK_SECRET` doesn't match this endpoint's signing secret (each endpoint has its own; test ≠ live). |
| "Manage subscription" errors | Billing Customer Portal not activated (step 4), or the user has no `stripe_customer_id` yet (never purchased). |
| Plan updates only after restart | Expected fallback isn't firing — the app refreshes on app re-activation + polls 2 min after checkout. Bring the app to the foreground. |
| Post-payment redirect 404s | `success_url` is `https://miraapp.ai?upgrade=success` — cosmetic only; payment still completes and the webhook still fires. Stand up a simple success page or change `success_url` in `stripe-checkout/index.ts` if you care. |

## Notes / gotchas baked into the code

- **Plan mapping lives in the webhook:** `customer.subscription.updated` maps the
  active price ID back to a plan by comparing to `STRIPE_PRICE_PRO/ULTRA`, so
  those secrets must be set for the **webhook**, not just checkout. Non-active
  statuses (past_due/canceled/unpaid) downgrade to `free`.
- **`profiles.plan` is authoritative** for every quota in the app (voice caps,
  monthly task runs, entitlements). Stripe → webhook → `profiles.plan` is the
  only path that grants paid features. A tampered client cannot self-upgrade.
- **Promo codes** are enabled in checkout (`allow_promotion_codes=true`) — create
  them in the dashboard if you want launch discounts.
- The app must be in **proxy mode with a signed-in user** for checkout to work
  (it already is: `MiraBackend.useProxy=true`).
