# GitHub
composio_toolkit: GITHUB

## When to use
User mentions: GitHub, repo, repository, issue, PR, pull request, branch, commit, CI, Actions, code review, merge, clone, fork, release, gist.

## Composio tools (prefix GITHUB_)

### Repos
- `GITHUB_LIST_REPOS_FOR_AUTHENTICATED_USER` — list user's repos
- `GITHUB_GET_REPO` — metadata, description, stars, forks

### Issues
- `GITHUB_LIST_ISSUES` — open/closed issues, filter by label/assignee
- `GITHUB_CREATE_AN_ISSUE` — title + body + labels + assignees (confirm first)
- `GITHUB_UPDATE_AN_ISSUE` — change state/title/body/labels
- `GITHUB_CREATE_AN_ISSUE_COMMENT` — comment on an issue

### Pull Requests
- `GITHUB_LIST_PRS` — open/closed PRs with filtering
- `GITHUB_GET_A_PULL_REQUEST` — full PR details, reviewers, CI status
- `GITHUB_CREATE_A_PULL_REQUEST` — base/head/title/body (confirm first)
- `GITHUB_MERGE_A_PULL_REQUEST` — requires explicit user approval
- `GITHUB_CREATE_A_REVIEW` — approve/request-changes/comment

### Files & Commits
- `GITHUB_LIST_REPO_CONTENTS` / `GITHUB_GET_REPO_CONTENT` — read files/dirs
- `GITHUB_CREATE_OR_UPDATE_FILE_CONTENTS` — write a file (confirm first)
- `GITHUB_LIST_COMMITS` / `GITHUB_GET_A_COMMIT` — history + diff

### Schema lookup
`COMPOSIO_GET_TOOL_SCHEMAS` when exact parameter names are unclear.

## Composio write safety rules
- Confirm before: create issue, open PR, merge, push file, close issue.
- Never merge without explicit user approval of owner/repo/PR#.
- Verify writes with a read-back when possible (re-fetch after create/update).
- Use exact schema key names — do NOT infer camelCase ↔ snake_case aliases.

## GitHub sub-topics (see dedicated docs for deep patterns)
- **Auth setup**: github-auth.md
- **Code review workflow**: github-code-review.md
- **Issues & triage**: github-issues.md
- **PR lifecycle**: github-pr-workflow.md
- **Repo management**: github-repo-management.md

## Canonical patterns

### "What open issues are on <owner>/<repo>?"
`GITHUB_LIST_ISSUES(owner, repo, state:"open")` → summarise titles + labels.

### "Create an issue: <title>"
Confirm title + body → `GITHUB_CREATE_AN_ISSUE`.

### "Review PR #N on <repo>"
`GITHUB_GET_A_PULL_REQUEST` → `GITHUB_LIST_COMMITS` → summarise changes, flag concerns.

### "Merge PR #N"
Confirm owner/repo/PR# → `GITHUB_MERGE_A_PULL_REQUEST`.

### "What files changed in the last commit?"
`GITHUB_LIST_COMMITS(per_page:1)` → `GITHUB_GET_A_COMMIT` → list files.

## Fallback (no Composio)
Use `gh` CLI via `run_shell_command`:
- `gh issue list --repo owner/repo`
- `gh pr create --title "..." --body "..."`
- `gh pr merge <number> --merge`

## Constraint
If GitHub toolkit not connected: "Open Mira Settings → Integrations and connect GitHub."
