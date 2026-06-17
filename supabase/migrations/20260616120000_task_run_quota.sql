-- Autonomous task-run metering + per-tier monthly quota (autonomy #3).
-- See project_mira_autonomy_direction. Meter unit = autonomous task runs / month.
--
-- task_runs        = one row per autonomous task executed (router or vision path).
-- consume_task_run = atomic check-and-record; enforces the per-plan monthly cap
--                    SERVER-SIDE, deriving the limit from profiles.plan (the
--                    Stripe-updated source of truth) so a tampered client cannot
--                    raise its own quota. Called with the user's JWT (auth.uid()).
-- task_run_quota   = read-only "tasks left" peek for the UI (no consume).

-- ── task_runs ────────────────────────────────────────────────────────────────
create table if not exists public.task_runs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  path        text not null,                 -- 'AX background' | 'AX-located cursor' | 'vision' | …
  success     boolean not null default true,
  cost_units  int not null default 0         -- per-task cost (steps proxy) for the cost ceiling
);

create index if not exists task_runs_user_created_idx
  on public.task_runs (user_id, created_at);

alter table public.task_runs enable row level security;

drop policy if exists "own task_runs read" on public.task_runs;
create policy "own task_runs read" on public.task_runs
  for select using (auth.uid() = user_id);
-- No user INSERT policy on purpose: rows are written only by consume_task_run
-- (security definer), so quota can't be bypassed by inserting directly.

-- ── per-plan monthly limit (-1 = uncapped) ──────────────────────────────────
create or replace function public.monthly_task_quota(p_plan text)
returns int language sql immutable as $$
  select case p_plan
    when 'free'  then 5
    when 'pro'   then 100
    when 'ultra' then 500
    else 5
  end;
$$;

-- ── atomic check-and-consume ────────────────────────────────────────────────
-- Returns jsonb { allowed, used, "limit", remaining, plan }.
create or replace function public.consume_task_run(
  p_path text, p_success boolean default true, p_cost int default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user  uuid := auth.uid();
  v_plan  text;
  v_limit int;
  v_used  int;
begin
  if v_user is null then
    return jsonb_build_object('allowed', false, 'error', 'not authenticated');
  end if;

  select plan into v_plan from public.profiles where user_id = v_user;
  v_plan  := coalesce(v_plan, 'free');
  v_limit := public.monthly_task_quota(v_plan);

  select count(*) into v_used
  from public.task_runs
  where user_id = v_user
    and created_at >= date_trunc('month', now());   -- current calendar month (UTC)

  if v_limit >= 0 and v_used >= v_limit then
    return jsonb_build_object('allowed', false, 'used', v_used,
                              'limit', v_limit, 'remaining', 0, 'plan', v_plan);
  end if;

  insert into public.task_runs (user_id, path, success, cost_units)
  values (v_user, p_path, p_success, p_cost);

  v_used := v_used + 1;
  return jsonb_build_object(
    'allowed', true, 'used', v_used, 'limit', v_limit,
    'remaining', case when v_limit < 0 then -1 else v_limit - v_used end,
    'plan', v_plan);
end; $$;

-- ── read-only quota peek (for "tasks left" UI) ──────────────────────────────
create or replace function public.task_run_quota()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user  uuid := auth.uid();
  v_plan  text;
  v_limit int;
  v_used  int;
begin
  if v_user is null then return jsonb_build_object('error', 'not authenticated'); end if;
  select plan into v_plan from public.profiles where user_id = v_user;
  v_plan  := coalesce(v_plan, 'free');
  v_limit := public.monthly_task_quota(v_plan);
  select count(*) into v_used from public.task_runs
   where user_id = v_user and created_at >= date_trunc('month', now());
  return jsonb_build_object(
    'used', v_used, 'limit', v_limit,
    'remaining', case when v_limit < 0 then -1 else greatest(v_limit - v_used, 0) end,
    'plan', v_plan);
end; $$;

grant execute on function public.consume_task_run(text, boolean, int) to authenticated;
grant execute on function public.task_run_quota() to authenticated;
