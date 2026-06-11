# GitHub Code Review
composio_toolkit: GITHUB

## When to use
User says: review PR, code review, review these changes, look at this PR, give feedback on PR #N, approve PR.

## Review workflow

### 1. Get PR details
`GITHUB_GET_A_PULL_REQUEST(owner, repo, pull_number)`
Shows: title, description, author, target branch, CI status, reviewers.

### 2. List commits
`GITHUB_LIST_COMMITS(owner, repo, sha:<head_branch>, per_page:20)`
Understand the change history.

### 3. Read changed files (when needed)
`GITHUB_GET_REPO_CONTENT(owner, repo, path:<file>)` — read current file state.

### 4. Submit review
`GITHUB_CREATE_A_REVIEW(owner, repo, pull_number, event:"COMMENT"|"APPROVE"|"REQUEST_CHANGES", body:"<overall comment>")`

Always confirm event type before submitting — APPROVE and REQUEST_CHANGES are visible to the PR author.

## Local review (before push)
`run_shell_command("git diff main...HEAD")` — see all changes since branch point.
`run_shell_command("git log main..HEAD --oneline")` — commit list.

## Review checklist to apply
- Security: SQL injection, XSS, exposed secrets, unsafe input handling
- Logic: edge cases, null handling, error paths
- Tests: coverage for new code
- Style: naming, duplication, complexity
- Breaking changes: API surface, database migrations

## Constraint
Confirm before APPROVE or REQUEST_CHANGES — these are visible actions on the PR.
