# Computer Use
tool: mcp__computer-use__* (local MCP server)

## When to use
User says: click, type in, open app, scroll, take a screenshot, drive, automate, operate, fill out, use the app, control my Mac, show me how.

Also use when: structured APIs (Composio, CLI) cannot complete a GUI task, a native macOS app must be operated, or the user explicitly asks for screen interaction.

## No-foreground contract — enforced at all times
The user's frontmost app MUST NOT change while Mira is working. Background work only. Do not steal focus, do not Cmd-Tab, do not raise windows the user is not looking at. This is the core promise of computer use in Mira.

## Tool sequence (always follow this order)
1. `mcp__computer-use__request_access` — list the apps you need
2. `mcp__computer-use__screenshot` — see current state before acting
3. Act with the most specific tool available (click > type > key)
4. `mcp__computer-use__screenshot` — verify the result

Never act without a fresh screenshot first. Never skip the verify step.

## App tiers (enforced by the MCP server)
- **Browsers** (Safari, Chrome, Arc, etc.) → `read` tier: screenshots only; clicking and typing blocked. Use `mcp__computer-use__open_application` for URL navigation.
- **Terminals / IDEs** (Terminal, VS Code, iTerm) → `click` tier: visible + left-clickable; typing blocked. Use Bash tool for shell commands instead.
- **Everything else** → `full` tier: no restrictions.

## Canonical patterns

### Open a URL in the user's browser (background)
Use `mcp__computer-use__open_application` with `bundle_id` + `urls:[...]`. This opens a new background window without stealing focus. Never use `open -a` or shell URL launching.

### Click a button / link
`screenshot` → identify element → `left_click` with coordinates. For form fields use `triple_click` to select then `type`.

### Take a screenshot of the desktop
`mcp__computer-use__screenshot` — returns the current display. Call `mcp__computer-use__list_granted_applications` first to confirm access.

### Scroll
`mcp__computer-use__scroll` with coordinate + direction + amount.

### Key press / hotkey
`mcp__computer-use__key` for single keys; `mcp__computer-use__hold_key` for modifier combos.

## Hard stops — always confirm before
- Form submission, send, purchase, payment
- Delete, archive, destructive action
- Account change, password field
- Any action the user has not explicitly approved

## Fallback hierarchy
1. Composio MCP (preferred for account-backed apps: GitHub, Gmail, Notion, Linear)
2. CLI / run_shell_command (preferred for file ops, build tools, git)
3. Computer Use (last resort for native GUI / no-API tasks)

Never silently substitute computer use for a missing Composio connector. Name the gap and tell the user to connect via Mira Settings → Integrations.
