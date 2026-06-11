# GitHub
composio_toolkit: GITHUB

## When to use
User mentions: issues, PRs, pull requests, repo, branch, commit, CI, GitHub Actions, code review, merge, clone, fork, release, gist.

## Composio tools (prefix GITHUB_)
- `GITHUB_LIST_REPOS_FOR_AUTHENTICATED_USER` — list user's repos
- `GITHUB_GET_REPO` — repo metadata, description, stars
- `GITHUB_LIST_ISSUES` / `GITHUB_CREATE_AN_ISSUE` / `GITHUB_UPDATE_AN_ISSUE`
- `GITHUB_LIST_PRS` / `GITHUB_GET_A_PULL_REQUEST` / `GITHUB_CREATE_A_PULL_REQUEST`
- `GITHUB_LIST_COMMITS` / `GITHUB_GET_A_COMMIT`
- `GITHUB_LIST_REPO_CONTENTS` / `GITHUB_GET_REPO_CONTENT` — read files
- `GITHUB_CREATE_OR_UPDATE_FILE_CONTENTS` — write files (confirm first)
- `GITHUB_CREATE_A_REVIEW` / `GITHUB_MERGE_A_PULL_REQUEST` — require confirmation
- Use `COMPOSIO_GET_TOOL_SCHEMAS` if a tool's exact parameters are unclear.

## Canonical patterns

### "What issues are open on <repo>?"
`GITHUB_LIST_ISSUES(owner, repo, state: "open")` → summarise top results.

### "Create an issue: <title>"
Confirm title + body with user, then `GITHUB_CREATE_AN_ISSUE`.

### "Review PR #N on <repo>"
`GITHUB_GET_A_PULL_REQUEST` → `GITHUB_LIST_COMMITS` → summarise changes, flag concerns.

### "Merge PR #N"
Always confirm owner/repo/PR number before `GITHUB_MERGE_A_PULL_REQUEST`.

## Constraints
- Confirm before any write: create issue, open PR, merge, push file.
- Never merge without user approval.
- If the toolkit isn't connected: "Open Mira Settings → Integrations and connect GitHub."
