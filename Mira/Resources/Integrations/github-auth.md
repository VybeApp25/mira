# GitHub Auth
composio_toolkit: GITHUB

## When to use
User says: authenticate GitHub, GitHub token, SSH key, gh login, clone private repo, push permission denied.

## Check current auth state
`run_shell_command("gh auth status 2>&1 || echo 'gh not installed'")`

## Auth paths

### gh CLI (preferred — richer API access)
`run_shell_command("gh auth login")`
Then verify: `run_shell_command("gh auth status")`

### HTTPS personal access token
1. Generate at github.com → Settings → Developer settings → Personal access tokens
2. `run_shell_command("git config --global credential.helper store")`
3. Next git operation will prompt for username + token

### SSH key
`run_shell_command("ssh-keygen -t ed25519 -C 'your@email.com' -f ~/.ssh/id_ed25519 -N ''")`
Then add public key to github.com → Settings → SSH and GPG keys.

## Composio connection
If user wants to connect GitHub to Mira's Composio integration:
Tell user: "Open Mira Settings → Integrations and connect GitHub."
Do NOT attempt OAuth from the agent.

## Constraint
If GitHub is connected via Composio, all read/write operations go through GITHUB_ tools — no token needed.
