-- ── Device lock ──────────────────────────────────────────────────────────────
-- Stores a SHA-256 hash of (IOKit serial + Keychain UUID) so we can enforce
-- "one free account per physical Mac" without storing any raw hardware IDs.

alter table public.profiles
  add column if not exists device_id_hash text;

-- Partial unique index: only one free account may claim a given device hash.
-- Paid accounts are exempt (they can sign in from any device).
create unique index if not exists profiles_device_free_uniq
  on public.profiles (device_id_hash)
  where plan = 'free' and device_id_hash is not null;

-- ── Spend alarm log ───────────────────────────────────────────────────────────
create table if not exists public.spend_alarm_log (
  id           bigserial    primary key,
  alerted_at   timestamptz  not null default now(),
  total_tokens bigint       not null,
  threshold    bigint       not null
);

alter table public.spend_alarm_log enable row level security;
-- No user-facing RLS policy — only service-role (edge fn) can write/read.

-- ── pg_cron + pg_net (pre-enabled on Supabase Pro) ───────────────────────────
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net  with schema extensions;

-- Hourly spend-alarm job.
-- The x-cron-secret value must match the CRON_SECRET edge-function secret.
-- To update the secret: run `supabase secrets set CRON_SECRET=<new_value>` and
-- then update the header value below via `select cron.unschedule('mira-spend-alarm')`
-- followed by re-running this block.
select cron.schedule(
  'mira-spend-alarm',
  '0 * * * *',
  $cron$
    select net.http_post(
      url     := 'https://rdbljrbjsmbfqwwpwwvn.supabase.co/functions/v1/spend-alarm',
      body    := '{}',
      headers := '{"Content-Type":"application/json","x-cron-secret":"8ea0e088fa7f77b8a96185a6943ac1a8aaef0cde"}'::jsonb
    );
  $cron$
);
