-- Community skills catalog (Gap B Phase 3). Text-only prompt skills; the body
-- is stored in-row (no storage bucket). AI-gated auto-publish: the skills-publish
-- edge fn (service role) sets status via a Claude moderation pass.
create table if not exists public.community_skills (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  tagline           text not null default '',
  category          text not null default 'Productivity',
  icon              text not null default 'sparkles',
  body              text not null,
  author_id         uuid references auth.users(id) on delete set null,
  author_handle     text,
  status            text not null default 'pending'
                      check (status in ('pending','approved','rejected')),
  moderation_reason text,
  downloads         integer not null default 0,
  created_at        timestamptz not null default now()
);

alter table public.community_skills enable row level security;

-- Anyone may read APPROVED skills (the public catalog).
drop policy if exists community_skills_public_read on public.community_skills;
create policy community_skills_public_read on public.community_skills
  for select using (status = 'approved');

-- Authors may read their own submissions in any state.
drop policy if exists community_skills_author_read on public.community_skills;
create policy community_skills_author_read on public.community_skills
  for select using (auth.uid() = author_id);

-- No client insert/update policy: writes go through the skills-publish edge fn
-- (service role), which validates + runs the moderation pass first.

-- Best-effort downloads counter (SECURITY DEFINER so it can bump an approved row
-- without a broad update policy).
create or replace function public.increment_skill_downloads(p_slug text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.community_skills
     set downloads = downloads + 1
   where slug = p_slug and status = 'approved';
end; $$;

create index if not exists community_skills_status_idx on public.community_skills (status);
