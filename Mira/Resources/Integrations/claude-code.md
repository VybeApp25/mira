# Claude Code Integration

Claude Code is Anthropic's agentic coding CLI. It runs in a terminal and can read, edit, and create files, execute shell commands, search codebases, and run multi-step coding workflows. Use it when the user wants to write, refactor, debug, or understand code in an actual project directory.

## When to use Claude Code vs Codex

- **Claude Code**: for full agentic coding sessions — multi-file edits, running tests, git ops, reading a whole repo. Best when the user says "fix this", "build this feature", "refactor X". Runs interactively or headless.
- **Codex** (run_coding_agent): for quick one-shot file generation tasks or when the user just wants a specific file produced. Use Codex when Claude Code authentication isn't confirmed.

## Launch modes

### Interactive (PTY — terminal session)
Used when the user wants to observe/control the session. Requires a visible terminal (tmux or an open Terminal.app window).

```
tmux new-session -d -s mira-code
tmux send-keys -t mira-code "claude" Enter
# Then pipe subsequent turns:
tmux send-keys -t mira-code "your prompt here" Enter
```

### Print mode (-p flag) — headless / programmatic
Best for Mira's background agent calls. Returns the final answer to stdout, exits when done. No interactive TTY needed.

```
claude -p "fix the failing tests in src/utils.test.ts" --output-format json
```

Print mode key flags:
- `--output-format json` — structured output (result, cost, turns)
- `--output-format text` — plain text (default)
- `--max-turns N` — cap agentic loop iterations (default: 10)
- `--model claude-opus-4-8` — override model
- `--no-stream` — wait for full response before printing

### Resume a session
```
claude --resume <session-id>          # resume last or named session
claude --continue                     # continue most recent conversation
```

## Authentication

```
claude auth login                     # OAuth browser flow (one-time setup)
claude auth status                    # check current auth state
claude doctor                         # full environment diagnostic
```

If the user says "Claude Code isn't working" or "authentication failed", run `claude doctor` first — it checks API key, node version, disk space, and config validity.

## Key CLI flags

| Flag | Purpose |
|------|---------|
| `-p "..."` | Print mode (headless) |
| `--output-format json\|text\|stream-json` | Output format |
| `--max-turns N` | Max agentic iterations |
| `--model MODEL` | Model override |
| `--no-stream` | Buffer full response |
| `--resume ID` | Resume a prior session |
| `--continue` | Continue most recent session |
| `--add-dir PATH` | Additional directory to grant access |
| `--allowedTools T1,T2` | Restrict tool set |
| `--disallowedTools T1` | Block specific tools |
| `--system-prompt FILE` | Override system prompt from file |
| `--append-system-prompt TEXT` | Append to system prompt |
| `--verbose` | Detailed logging |
| `--debug` | Debug output including API calls |

## Configuration files

- `~/.claude/settings.json` — global settings (model, hooks, env vars, tool permissions)
- `.claude/settings.json` in project root — project-level overrides (checked into git)
- `.claude/settings.local.json` — local project overrides (gitignored)
- `CLAUDE.md` in project root — persistent instructions Claude reads at session start

### settings.json structure
```json
{
  "model": "claude-opus-4-8",
  "env": { "NODE_ENV": "development" },
  "permissions": {
    "allow": ["Bash(npm test)", "Read"],
    "deny":  ["Bash(rm -rf)"]
  }
}
```

## Slash commands (interactive mode)

| Command | What it does |
|---------|-------------|
| `/help` | Show all commands |
| `/clear` | Clear conversation context |
| `/compact` | Summarize context to save tokens |
| `/memory` | View/edit CLAUDE.md memory |
| `/doctor` | Run environment diagnostic |
| `/cost` | Show token/cost for session |
| `/model` | Switch model mid-session |
| `/review` | Trigger code review agents |

## Hooks

Claude Code supports lifecycle hooks in `settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "echo 'running bash'" }] }],
    "PostToolUse": [...],
    "Stop": [{ "hooks": [{ "type": "command", "command": "notify-send 'Claude done'" }] }]
  }
}
```

Hook events: `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`

## MCP server wiring

Claude Code can use MCP servers defined in its settings:

```json
{
  "mcpServers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"] }
  }
}
```

## Mira usage patterns

**Start a coding task in the agent folder:**
```
claude -p "your task" --add-dir ~/Desktop/Mira
```

**Run headless with JSON result:**
```
claude -p "explain the bug in app.py" --output-format json --max-turns 5
```

**Check if Claude Code is installed:**
```
which claude && claude --version
```

If not installed: `npm install -g @anthropic-ai/claude-code`

## Hard stops

- Never run Claude Code with `--dangerously-skip-permissions` unless the user explicitly confirms
- Never pass API keys via CLI flags; Claude Code reads `ANTHROPIC_API_KEY` from env or `~/.claude/settings.json`
- Always use `--max-turns` when calling programmatically to prevent runaway loops
