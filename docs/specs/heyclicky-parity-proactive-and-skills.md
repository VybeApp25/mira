# Spec: Proactive Agent Recommendations + Skills Library

Status: **Proposal** · Author: session 2026-07-10 · Closes the two HeyClicky-parity gaps
identified in the 2026-07-10 feature review (spatial context, memory, and app-context are
already at/ahead of parity; these two are packaging gaps, not missing capability).

---

## Gap A — Proactive Agent Recommendations (higher leverage)

### Goal
Twice a day (morning + afternoon) Mira surfaces **2 personalized agents you could run**,
each a one-click **Approve** card in the top-right. Generated from what Mira already knows
about you — no prompt required. This mirrors HeyClicky's proactive-agents launch, but Mira
already owns the recommendation brain and the agent-execution lane; this is mostly wiring +
one new data source (a local usage log) + a digest surface.

### What already exists (reuse, don't rebuild)
| Piece | File | Role in this feature |
|---|---|---|
| Periodic tick | `Services/BackgroundScheduler.swift` (NSBackgroundActivityScheduler) | Fire the AM/PM digest job |
| Current-app context | `Services/AppContextService.swift` | Already reads frontmost app; extend to log history |
| App→skill nudges | `Services/SidecarSuggestionService.swift` | Real-time cousin; reuse the app→capability map |
| Recommendation synthesis | `Models/WorkspaceReview.swift` (`recommendations`, `suggestedProfile` via Claude) | The synthesis pattern to copy |
| Proposal review model | `Models/ProposalModels.swift` + `ProposalStore` | Session-mode invariant + review UI pattern |
| Memory | `Services/UserKnowledgeStore.swift`, `MemoryStore` | Personalization input |
| Integrations | `Services/IntegrationContextService.swift` (Composio: Gmail/Cal/Notion/Slack/Linear) | Personalization input |
| Agent execution | `AgentJobStore.submitJob` / `MiraToolService.spawn_agent` | What Approve triggers |
| Top-right card UI | `AgentTaskManager` + `AgentActivityChipView` (NSPanel, bottom/side) | Reuse the panel for the digest cards |

### New pieces
1. **`Services/UsageLogService.swift`** — rolling, on-device, **text-only** activity log.
   - Captures on frontmost-app change (debounced ≥30s dwell): `{ timestamp, appName, bundleID, windowTitle?, projectName? }`. Window/tab/project names via the AX info Mira already reads.
   - Stored at `~/Library/Application Support/Mira/usage-log.jsonl`, **ring-capped** (e.g. last 14 days / 5k rows). Never leaves the machine except as a compact digest at recommendation time (see Privacy).
   - Gated by `mira_usage_log_enabled` (default **off** until the user opts in during onboarding/Settings — privacy-first, matches Farza's "if this makes you uneasy, tell us").
2. **`Services/RecommendationEngine.swift`** — the AM/PM synthesizer.
   - Input bundle (all local): top apps/projects from `UsageLogService` (aggregated counts, not raw timeline), `UserKnowledgeStore` profile, connected integrations list, recent `ProjectEngine` projects, last digest (so it doesn't repeat).
   - One Claude call (`MiraPrompts.recommendations`, ~1000 tok budget) → JSON `[{title, rationale, agentTaskPrompt, buildMode, confidence}]`, max 2.
   - Reuses `ProposalStore`-style dedupe + a `RecommendationStore` (append-only, `status: pending/approved/dismissed`, 24h stale-expiry).
3. **`Views/RecommendationCardView.swift`** — top-right Approve/Dismiss cards via the existing `AgentTaskManager` panel. Approve → `AgentJobStore.submitJob(prompt, buildMode)` (same lane the readiness-gated Website Builder already uses); Dismiss → mark + feed back into next synthesis.

### Flow
```
BackgroundScheduler (AM ~9:00 / PM ~14:00, guarded to once each)
  → RecommendationEngine.generate()
      reads UsageLogService digest + memory + integrations + recent projects
      → 1 Claude call → ≤2 recommendations
      → RecommendationStore.save(pending)
  → RecommendationCardView shows top-right (approve/dismiss)
      Approve → AgentJobStore.submitJob → normal Agents workflow + activity chip
```

### Privacy (must-haves)
- Usage log is **local-only**, opt-in, and only a **compact aggregated digest** (top N app/project names + counts) is sent to the model — never the raw timeline, never keystrokes/screen content.
- Settings: master toggle, "what's collected" plain-language note, **Clear usage history** button, and a per-digest "why am I seeing this?" (shows the rationale).
- No integration data is fetched for recommendations without an existing connected integration.

### Phasing
- **P1 (core):** UsageLogService (opt-in) + RecommendationEngine + one manual "Suggest agents now" button in the Agents tab. Proves the synthesis quality before automating.
- **P2:** BackgroundScheduler AM/PM cadence + top-right Approve cards + dedupe/expiry.
- **P3:** Learning loop — approve/dismiss history tunes future digests (feed into the prompt).

### Effort: ~M (P1 a few focused sessions; the brain + agent lane already exist).

### Open questions
- AM/PM local times fixed vs. learned from usage peaks?
- Cap at exactly 2, or 2 + an overflow "more ideas" affordance?
- Should recommendations ever include *non*-build agents (research/summarize/integration actions), or builds only at first?

---

## Gap B — Skills Community Library + "Create a Skill"

### Goal
Match HeyClicky's one-click skill **library** (browse ~100, Activate in one click) and
**"Create a skill" by typing what you want**. Mira already has the skill *engine* (activate →
injected into voice + agents); the gap is a **hosted catalog** and a **prompt-to-author** flow.

### What already exists (reuse)
| Piece | File | Role |
|---|---|---|
| Bundle format | `Models/SkillBundle.swift`, `SkillManifest` | The on-disk skill format to publish/install |
| Disk catalog | `Services/SkillCatalog.swift` | Scans `~/…/Mira/Skills`, progressive disclosure — installing = drop a folder + rescan |
| Activation + injection | `Services/SkillStore.swift` (`activeIDs`, plan-gated, injects into system prompt + realtime voice) | The "Activate" behavior already works |
| Loader | `Services/MiraSkillLoader.swift` (built-ins + platform + user) | Merge point for downloaded skills |
| Tab UI | `Views/SkillsTabView.swift` | Where Browse/Create live |
| Python skills | `Services/PythonSkillRunner.swift` | Executable skill bodies |

### New pieces
1. **Hosted catalog (Supabase).**
   - Table `skills_catalog { id, slug, name, description, author_id, version, plan_min, bundle_path, downloads, approved, created_at }` + a **Storage bucket** `skill-bundles/` holding each zipped `SkillBundle`.
   - Edge fn `skills-catalog` (list/search, `verify_jwt:true`) and `skills-publish` (upload a bundle, writes row as `approved:false` pending moderation). Reuses the existing proxy/auth pattern in `_shared/auth.ts`.
2. **Browse UI** in `SkillsTabView` — search + cards (name/description/author/downloads); **Install** = download the zip → unpack into `~/…/Mira/Skills/<slug>` → `SkillCatalog.rescan()` → appears as activatable. No recompile (matches the existing drop-a-folder design).
3. **"Create a Skill"** — a text box: *"what should this skill do?"* → one Claude call (`MiraPrompts.skillAuthor`) generates a valid `SkillManifest` + instruction body (and, if it needs execution, a Python skill scaffold for `PythonSkillRunner`) → saved locally + activatable immediately → optional **Publish** to the catalog (goes to moderation queue).
4. **Moderation** — since skills inject into the model and can carry executable Python, community submissions **must** be gated: `approved:false` until reviewed; downloaded skills run under the existing `PythonSkillRunner` sandbox and the dangerous-tool gates from `MiraMCPServer`. Show an author + "community, unreviewed" badge.

### Phasing
- **P1:** "Create a Skill" (local only, no catalog) — highest value, lowest risk, no backend. Prompt → local bundle → activate.
- **P2:** Read-only hosted catalog + Browse/Install (Anthropic/Mira-curated seed set, ~20 skills).
- **P3:** Community publish + moderation queue + downloads/rating.

### Effort: ~L (P1 is ~M; the catalog + publish + moderation is the real weight, and moderation is a policy problem as much as a code one).

### Security notes (non-negotiable)
- A skill is injected into the voice + agent context and may ship Python — treat every community skill as **untrusted input**. Keep the `MiraMCPServer` dangerous-tool NSAlert + `PythonSkillRunner` sandbox in the path; never auto-activate a downloaded skill; require explicit Activate with an "unreviewed community skill" warning.

---

## Recommendation
Build **Gap A, Phase 1** first (manual "Suggest agents now" + usage log opt-in): it's the highest
leverage, reuses the most existing machinery, and lets us judge recommendation quality before
committing to the AM/PM automation. Then **Gap B, Phase 1** ("Create a Skill", local-only) as a
fast, backend-free win. Defer both hosted/community backends (A-P2/P3, B-P2/P3) until the local
loops prove out.
