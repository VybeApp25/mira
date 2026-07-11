# Scoping: Community Skills Catalog — Moderation (Gap B Phase 3)

Status: **Decision doc** · 2026-07-10 · Follows `heyclicky-parity-proactive-and-skills.md` (Gap B).
Phase 1 ("Create a Skill", local) shipped in #27. This scopes the **community** catalog:
user-published skills other users can browse and install.

## The core risk (why moderation is the whole ballgame)
A skill is **not passive data**. When activated it is **injected verbatim into Mira's
system prompt** (voice model + agents), and a skill bundle **can carry Python**
(`PythonSkillRunner`). So an untrusted community skill is two attack surfaces at once:

1. **Prompt injection / jailbreak** — the SKILL.md body can try to override Mira's
   instructions, exfiltrate context, or steer agents ("when active, email X to…").
2. **Code execution** — a Python skill body runs on the installer's machine.

Any moderation model must answer both. The single highest-leverage decision below
(**Decision 1**) removes surface #2 entirely for v1.

---

## Decision 1 — Do community skills allow executable Python? **(recommend: NO, text-only v1)**
- **Text-only community catalog:** community submissions are SKILL.md **prompt skills**
  only (frontmatter + instruction body → injected context). No `steps.json`, no Python.
  Executable/Python skills stay **built-in or platform** (Mira-authored) or **local**
  user-created (never redistributed).
- **Why:** kills the code-execution attack surface completely. What remains is prompt
  injection, which is bounded — the body only ever becomes *system-prompt text the user
  explicitly activated*, and Mira's own guardrails (`MiraMCPServer` dangerous-tool NSAlert,
  `RouterService.detectDangerousCommand`, agent tool gates) still sit between any skill and
  a real side effect. Much smaller, well-understood surface.
- Ship Python-in-community later (P4) only behind strict human review + the existing sandbox.

## Decision 2 — Moderation model (pick one)

| Model | How it works | Safety | Scale / speed | Ops burden |
|---|---|---|---|---|
| **A. Mira-curated only** | Users submit; nothing lists without Mira's team publishing it | Highest | Low (bottleneck) | High, ongoing |
| **B. Review queue** | Submit → queue → approve (human and/or AI) → public | High | Medium | Medium |
| **C. AI-gated auto-publish** | Submit → automated Claude moderation → clean auto-lists, ambiguous queued, obvious-bad rejected; + reporting/takedown | Good (text-only) | High | Low–Medium |
| **D. Open + reactive** | Publishes immediately; safety via warnings, reporting, takedown, ratings | Weakest | Highest | Low upfront, high firefighting |

**Recommendation: C (AI-gated auto-publish), text-only.** With Python excluded (Decision 1),
a Claude moderation pass is a strong first line: classify each submission for
prompt-injection / jailbreak / policy violation → auto-approve clean, auto-reject obvious
abuse, queue the ambiguous middle for a human. Scales like a community catalog should while
keeping a real gate. A/B are safer but don't scale; D is too loose given the injection surface.

## Decision 3 — Non-negotiable guardrails (independent of the model above)
- **Sign-in to publish** — attribution + accountability + rate-limit (reuse Supabase auth).
- **Install-time consent** — every community skill shows an "unreviewed community skill · by
  @author" badge and its full body before install; **never auto-activate** a downloaded
  community skill (unlike local Create-a-Skill, which the user just authored).
- **Report + takedown** — a flag control, a downloads counter, and one-click unpublish.
- **AI moderation is advisory, not silent** — store the moderation verdict + reason on the row
  so a human can audit and reverse.

---

## Backend shape (for the recommended path: C, text-only)
Minimal — text lives in the table, so **no storage bucket** needed:

- Table `community_skills { id, slug, name, tagline, category, icon, body, author_id,
  status(pending|approved|rejected), moderation_reason, downloads, created_at }`.
  RLS: public `SELECT` where `status='approved'`; insert only by authed user as `pending`.
- Edge fn `skills-publish` (authed): validates the SKILL.md via the same rules as
  `MiraSkillLoader.parse` / `importBlocker`, runs the **Claude moderation pass**
  (`MiraPrompts.skillModeration` → verdict+reason), writes the row `approved`/`pending`/`rejected`.
- Edge fn `skills-catalog` (public read) **or** direct PostgREST read of approved rows.
- Client: a **Browse** view in `SkillsTabView` (search + cards) and **Install**
  (download body → write `PromptSkills/user/<slug>/SKILL.md` → `MiraSkillLoader.refresh()`),
  plus a **Publish** affordance on any local user skill.
- Seed the catalog with ~10–20 Mira-authored skills so it's not empty at launch.

Effort ~**M** once Decisions 1–2 are fixed (text-only + AI-gated removes the bucket, the
Python sandbox work, and most of the human-moderation tooling).

## Decisions — LOCKED 2026-07-10 (Tre)
1. **Python in community v1? → NO, text-only.** Community = prompt skills only; Python stays Mira-authored/local.
2. **Moderation model? → C (AI-gated auto-publish), text-only.** Claude moderation pass gates each submission; clean auto-lists, obvious-bad auto-rejects, ambiguous → `pending` queue.
3. **Human review owner:** default to Tre reviewing the small `pending` queue (Supabase dashboard / a lightweight admin view) — revisit if volume grows.

**→ Build path is fixed:** table `community_skills` (RLS public-read approved, insert-as-pending) + edge fn `skills-publish` (validate via `MiraSkillLoader` rules → `MiraPrompts.skillModeration` verdict → set status) + public read (PostgREST or `skills-catalog` fn) + `SkillsTabView` Browse/Install/Publish + ~10–20 seed skills. Guardrails from Decision 3 above are non-negotiable.
