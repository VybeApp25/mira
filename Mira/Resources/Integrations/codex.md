# Codex CLI Integration

Delegate coding tasks to [OpenAI Codex CLI](https://github.com/openai/codex) — an autonomous coding agent that can build features, refactor code, fix bugs, review PRs, and run batch issue fixes.

Codex is available in Mira alongside Claude Code CLI (`claude -p`). Use Codex for OpenAI-auth workflows or when the user explicitly asks for it.

## When to Use Codex vs Claude Code

| Signal | Use |
|--------|-----|
| User says "use Codex" / "run Codex" | Codex CLI |
| OpenAI key/auth configured | Codex CLI |
| Feature building, PR reviews, batch issue fixing | Either (Codex preferred for git-heavy workflows) |
| Multi-file refactor with project context | Claude Code (`claude -p`) |
| Mira's default agent folder output | Claude Code via `run_coding_agent` |

## Primary: Claude Code Agent (default)

`run_coding_agent(prompt:"<task>", cwd?:"<abs_project_path>", model?:"haiku|sonnet|opus", budget_usd?:0.20)`

- haiku for quick lookups, sonnet for multi-file edits (default), opus for hard reasoning
- Always provide `cwd` when working on a specific project
- Cap `budget_usd` at 0.50 for large tasks
- Agent has full file read/write/shell access inside `cwd`

## Alternative: Codex CLI

### Prerequisites

- **Install:** `npm install -g @openai/codex`
- **Auth (choose one):**
  - Set `OPENAI_API_KEY` env var
  - Run `codex auth login` (OAuth browser flow — `~/.codex/auth.json`)
- **Must be inside a git repo** — use `mktemp -d && git init` for scratch work
- **Always `pty=true`** in terminal calls — Codex is interactive and hangs without it

### One-Shot Tasks

```bash
codex exec 'Add dark mode toggle to Settings' --full-auto
codex exec 'Refactor auth module to use async/await' --full-auto

# Scratch work (needs git repo)
cd $(mktemp -d) && git init && codex exec 'Build a snake game in Python' --full-auto
```

### Key Flags

| Flag | Effect |
|------|--------|
| `exec "prompt"` | One-shot, exits when done |
| `--full-auto` | Sandboxed, auto-approves file changes in workspace |
| `--yolo` | No sandbox, no approvals (fastest, most dangerous) |
| `--model MODEL` | Override model (e.g., `o4-mini`, `gpt-4o`) |

### Background Mode (Long Tasks)

```bash
terminal(command="codex exec --full-auto 'Refactor the auth module'", workdir="~/project", background=true, pty=true)
# Returns session_id
process(action="poll", session_id="<id>")
process(action="log", session_id="<id>")
process(action="submit", session_id="<id>", data="yes")  # answer Codex questions
```

### PR Reviews

```bash
REVIEW=$(mktemp -d) && git clone https://github.com/user/repo.git $REVIEW
cd $REVIEW && gh pr checkout 42 && codex review --base origin/main
```

### Parallel Issue Fixing with Worktrees

```bash
git worktree add -b fix/issue-78 /tmp/issue-78 main
git worktree add -b fix/issue-99 /tmp/issue-99 main

terminal(command="codex --yolo exec 'Fix issue #78: <description>. Commit when done.'", workdir="/tmp/issue-78", background=true, pty=true)
terminal(command="codex --yolo exec 'Fix issue #99: <description>. Commit when done.'", workdir="/tmp/issue-99", background=true, pty=true)

process(action="list")  # monitor both

cd /tmp/issue-78 && git push -u origin fix/issue-78
gh pr create --repo user/repo --head fix/issue-78 --title "fix: ..." --body "..."
git worktree remove /tmp/issue-78
```

## Mira's Codex Route

When the user asks Mira to "use Codex" or "run Codex on my project":
- Mira's CodexService detects the `codex` binary via `which codex`
- Runs `codex exec "<prompt>" --full-auto` in the agent folder or specified workdir
- Auto-inits a git repo in the workdir if missing
- Falls back to `run_coding_agent` (Claude Code) if Codex is not installed

Check Codex install status: ask Mira "is Codex installed?" or check Settings → Dev Tools.

## Rules

1. Always `pty=true` in terminal calls — Codex hangs without it
2. Git repo required — auto-init with `git init` for scratch work
3. Use `exec "prompt"` for one-shots (exits cleanly when done)
4. Use `--full-auto` for building (auto-approves workspace changes)
5. Background + `process` poll for tasks > 30 seconds
6. Never use `--yolo` unless the user explicitly requests it
7. Parallel worktrees are safe for batch work
8. Never interfere with a running Codex session — poll and wait
