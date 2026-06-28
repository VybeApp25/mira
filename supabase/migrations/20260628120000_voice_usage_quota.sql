-- Free-tier voice (OpenAI Realtime) throttle — abuse / gross-margin guard.
--
-- Realtime audio is Mira's most expensive per-user COGS and was previously
-- UNCAPPED: mint-realtime-token gated on auth but recorded 0 usage, so a free
-- user could mint unlimited sessions = unlimited expensive audio minutes. The
-- per-provider daily TOKEN budget (see usage / checkQuota) never caught it
-- because realtime audio is not token-metered there.
--
-- This adds a server-authoritative DAILY voice cap, enforced at mint time:
--   • sessions/day — hard cap; every mint counts one session (can't be bypassed,
--     identity comes from the verified JWT, counting is server-side).
--   • seconds/day  — soft cap; the client reports real session duration on
--     teardown (report-voice-usage). A tampered client can only UNDER-report,
--     which the hard session cap already bounds.
--
-- Window is the calendar day (UTC) so free users get a fresh allowance daily.

-- ── voice_usage (mirrors public.usage, one row per user per day) ─────────────
create table if not exists public.voice_usage (
  user_id      uuid    not null references auth.users(id) on delete cascade,
  window_start date    not null default current_date,   -- daily window (UTC)
  sessions     int     not null default 0,              -- minted realtime sessions
  seconds      int     not null default 0,              -- client-reported audio seconds
  primary key (user_id, window_start)
);

create index if not exists voice_usage_user_window_idx
  on public.voice_usage (user_id, window_start);

alter table public.voice_usage enable row level security;

-- A user may read only their own rows; writes happen only via the service-role
-- edge functions (add_voice_usage, security definer). No user write policy.
drop policy if exists "own voice_usage read" on public.voice_usage;
create policy "own voice_usage read" on public.voice_usage
  for select using (auth.uid() = user_id);

-- ── per-plan daily voice caps (-1 = uncapped) ───────────────────────────────
-- Returns { sessions, seconds }. Tune freely — this is the server-side cost
-- ceiling a stolen/tampered session cannot exceed.
create or replace function public.daily_voice_caps(p_plan text)
returns jsonb language sql immutable as $$
  select case p_plan
    when 'free'  then jsonb_build_object('sessions',   5, 'seconds',    600)  -- 10 min/day
    when 'pro'   then jsonb_build_object('sessions', 100, 'seconds',  36000)  -- 10 hr/day
    when 'ultra' then jsonb_build_object('sessions',  -1, 'seconds',     -1)  -- uncapped
    else              jsonb_build_object('sessions',   5, 'seconds',    600)
  end;
$$;

-- ── atomic voice-usage increment (called by edge functions via service role) ─
-- p_sessions: +1 at mint, 0 on a seconds-only report.
-- p_seconds : client-reported duration on session teardown.
create or replace function public.add_voice_usage(
  p_user uuid, p_sessions int, p_seconds int
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.voice_usage (user_id, window_start, sessions, seconds)
  values (p_user, current_date, greatest(p_sessions, 0), greatest(p_seconds, 0))
  on conflict (user_id, window_start) do update
    set sessions = public.voice_usage.sessions + excluded.sessions,
        seconds  = public.voice_usage.seconds  + excluded.seconds;
end; $$;

-- ── read-only voice-quota peek (for a "voice minutes left" UI, optional) ─────
-- Returns { plan, sessions_used, sessions_limit, seconds_used, seconds_limit }.
create or replace function public.voice_quota()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_plan text;
  v_caps jsonb;
  v_s    int;
  v_sec  int;
begin
  if v_user is null then return jsonb_build_object('error', 'not authenticated'); end if;
  select plan into v_plan from public.profiles where user_id = v_user;
  v_plan := coalesce(v_plan, 'free');
  v_caps := public.daily_voice_caps(v_plan);
  select coalesce(sessions, 0), coalesce(seconds, 0) into v_s, v_sec
    from public.voice_usage where user_id = v_user and window_start = current_date;
  return jsonb_build_object(
    'plan',           v_plan,
    'sessions_used',  coalesce(v_s, 0),
    'sessions_limit', (v_caps->>'sessions')::int,
    'seconds_used',   coalesce(v_sec, 0),
    'seconds_limit',  (v_caps->>'seconds')::int);
end; $$;

grant execute on function public.voice_quota() to authenticated;
-- add_voice_usage + daily_voice_caps are called only by service-role edge
-- functions, so no authenticated grant (RLS-bypassing service role already has it).
