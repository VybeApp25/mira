# GitHub PR Workflow
composio_toolkit: GITHUB

## When to use
User says: open a PR, create pull request, push my branch, submit for review, merge PR, what's the CI status.

## Full PR lifecycle

### 1. Prepare branch (local)
`run_shell_command("git checkout -b feature/<name>")`
`run_shell_command("git add <files> && git commit -m '<message>'")`
`run_shell_command("git push -u origin feature/<name>")`

### 2. Create PR (confirm first)
`GITHUB_CREATE_A_PULL_REQUEST(owner, repo, title, body, head:"feature/<name>", base:"main")`
Always confirm title + body + base branch before creating.

### 3. Monitor CI status
`GITHUB_GET_A_PULL_REQUEST(owner, repo, pull_number)` → check `mergeable_state` and CI check runs.

### 4. Respond to review
`run_shell_command("git push")` after additional commits — PR auto-updates.

### 5. Merge (explicit approval required)
`GITHUB_MERGE_A_PULL_REQUEST(owner, repo, pull_number, merge_method?:"merge"|"squash"|"rebase")`
ALWAYS confirm owner/repo/PR number/merge method before merging.

## Fallback (gh CLI)
- `run_shell_command("gh pr create --title '...' --body '...' --base main")`
- `run_shell_command("gh pr status")`
- `run_shell_command("gh pr merge <number> --squash")`

## Canonical patterns

### "Open a PR for my current branch"
Check current branch → confirm title/body → `GITHUB_CREATE_A_PULL_REQUEST`.

### "What's the status of PR #N?"
`GITHUB_GET_A_PULL_REQUEST` → show CI status, reviewer approvals, merge readiness.

### "Merge PR #N with squash"
Confirm all details → `GITHUB_MERGE_A_PULL_REQUEST`, merge_method:"squash".

## Constraint
Never merge without the user explicitly approving the exact PR number and merge method.
Force-push (`git push --force`) only on explicit user request — warn about shared branches.
