# GitHub Repo Management
composio_toolkit: GITHUB

## When to use
User says: create repo, clone, fork, repo settings, branches, releases, secrets, archive repo.

## Operations

### Get repo info
`GITHUB_GET_REPO(owner, repo)` — stars, forks, default branch, visibility, topics.

### List repos
`GITHUB_LIST_REPOS_FOR_AUTHENTICATED_USER(per_page?:30, sort?:"updated")` — user's repos.

### List / read repo contents
`GITHUB_LIST_REPO_CONTENTS(owner, repo, path?:"")` — directory listing.
`GITHUB_GET_REPO_CONTENT(owner, repo, path)` — read a file.

### Write a file (confirm first)
`GITHUB_CREATE_OR_UPDATE_FILE_CONTENTS(owner, repo, path, message, content, sha?)` — content must be base64. Confirm before writing. Verify with a subsequent read.

### Create / clone repo (gh CLI)
- Create: `run_shell_command("gh repo create <name> --public --clone")`
- Clone: `run_shell_command("gh repo clone <owner>/<repo>")`
- Fork: `run_shell_command("gh repo fork <owner>/<repo> --clone")`

### Releases (gh CLI)
- Create: `run_shell_command("gh release create v1.0.0 --title 'v1.0.0' --notes '...' --repo owner/repo")`
- List: `run_shell_command("gh release list --repo owner/repo")`

### Branches
- List: `run_shell_command("git branch -a")`
- Delete remote: `run_shell_command("git push origin --delete <branch>")` — confirm first.

## Canonical patterns

### "Create a new GitHub repo called <name>"
`gh repo create` → confirm public/private → clone locally.

### "What files are in <owner>/<repo>?"
`GITHUB_LIST_REPO_CONTENTS` → show directory tree.

### "Read the README of <repo>"
`GITHUB_GET_REPO_CONTENT`, path:"README.md" → decode base64 content → display.

### "Tag a release v<N>"
Confirm version + notes → `gh release create`.

## Constraint
Confirm before any write, delete, or destructive operation. Never delete branches the user hasn't explicitly identified as safe to remove.
