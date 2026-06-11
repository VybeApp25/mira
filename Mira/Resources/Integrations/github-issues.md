# GitHub Issues
composio_toolkit: GITHUB

## When to use
User says: create issue, open bug report, what issues are open, triage, label issue, assign issue, close issue.

## Operations

### List issues
`GITHUB_LIST_ISSUES(owner, repo, state:"open"|"closed"|"all", labels?:"bug,help-wanted", assignee?:"username", per_page?:20)`

### Create issue (confirm first)
`GITHUB_CREATE_AN_ISSUE(owner, repo, title, body, labels?:[], assignees?:[])`
Always confirm title + body with user before creating.

### Update issue
`GITHUB_UPDATE_AN_ISSUE(owner, repo, issue_number, state?:"open"|"closed", title?, body?, labels?, assignees?)`

### Comment on issue
`GITHUB_CREATE_AN_ISSUE_COMMENT(owner, repo, issue_number, body)`

### Close issue
`GITHUB_UPDATE_AN_ISSUE(owner, repo, issue_number, state:"closed")` — confirm first.

## Fallback (gh CLI)
- `run_shell_command("gh issue list --repo owner/repo --state open")`
- `run_shell_command("gh issue create --title '...' --body '...' --repo owner/repo")`
- `run_shell_command("gh issue close <number> --repo owner/repo")`

## Canonical patterns

### "What bugs are open on <repo>?"
`GITHUB_LIST_ISSUES`, label:"bug" → list title + number.

### "Create a bug report for <problem>"
Confirm title/body → `GITHUB_CREATE_AN_ISSUE`, labels:["bug"].

### "Assign issue #N to me"
`GITHUB_UPDATE_AN_ISSUE`, assignees:[username].

### "Close issue #N — fixed in PR #M"
Confirm → `GITHUB_UPDATE_AN_ISSUE`, state:"closed" + comment linking PR.

## Constraint
Always confirm before creating or closing issues. Verify with `GITHUB_GET_AN_ISSUE` after creating.
