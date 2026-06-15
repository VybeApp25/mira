-- Backend secrets proxy — schema (release blocker #1)
-- See docs/architecture/backend_secrets_proxy.md
-- profiles = per-user plan (source of truth; a Stripe webhook updates `plan`).
-- usage    = per-user, per-provider, per-day metering for quota enforcement.

-- ── profiles ────────────────────────────────────────────────────────────────
create table if not exists public.profiles (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  plan               text not null default 'free' check (plan in ('free','pro','ultra')),
  stripe_customer_id text,
  updated_at         timestamptz not null default now()
);

-- ── usage ───────────────────────────────────────────────────────────────────
create table if not exists public.usage (
  user_id       uuid    not null references auth.users(id) on delete cascade,
  provider      text    not null,                      -- 'anthropic' | 'openai' | 'assemblyai' | …
  window_start  date    not null default current_date, -- daily window
  requests      int     not null default 0,
  input_tokens  bigint  not null default 0,
  output_tokens bigint  not null default 0,
  primary key (user_id, provider, window_start)
);

-- ── auto-create a free profile on sign-up ───────────────────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── atomic usage increment (called by edge functions via service role) ──────
create or replace function public.add_usage(
  p_user uuid, p_provider text, p_requests int, p_input bigint, p_output bigint
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.usage (user_id, provider, window_start, requests, input_tokens, output_tokens)
  values (p_user, p_provider, current_date, p_requests, p_input, p_output)
  on conflict (user_id, provider, window_start) do update
    set requests      = public.usage.requests      + excluded.requests,
        input_tokens  = public.usage.input_tokens  + excluded.input_tokens,
        output_tokens = public.usage.output_tokens + excluded.output_tokens;
end; $$;

-- ── RLS: a user may read only their own rows; writes happen only via the
--    service-role edge functions (which bypass RLS). No user write policies. ──
alter table public.profiles enable row level security;
alter table public.usage    enable row level security;

drop policy if exists "own profile read" on public.profiles;
create policy "own profile read" on public.profiles
  for select using (auth.uid() = user_id);

drop policy if exists "own usage read" on public.usage;
create policy "own usage read" on public.usage
  for select using (auth.uid() = user_id);
