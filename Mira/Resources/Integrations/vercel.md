# Vercel
composio_toolkit: VERCEL

## When to use
User mentions: deploy, Vercel, deployment, production, preview, domain, environment variable, build logs.

## Composio tools (prefix VERCEL_)
- `VERCEL_LIST_PROJECTS` — list user's Vercel projects
- `VERCEL_GET_PROJECT` — project details
- `VERCEL_LIST_DEPLOYMENTS` — recent deployments with status
- `VERCEL_GET_DEPLOYMENT` — deployment details and logs
- `VERCEL_CREATE_DEPLOYMENT` — trigger a new deployment (confirm first)
- `VERCEL_LIST_DOMAINS` — domains assigned to a project
- `VERCEL_ADD_PROJECT_ENV` — add environment variable (confirm before)

## Canonical patterns

### "What's the status of my latest deployment?"
`VERCEL_LIST_PROJECTS` → pick matching project → `VERCEL_LIST_DEPLOYMENTS(limit:1)` → report state + url.

### "Deploy my <project>"
Confirm project name and branch → `VERCEL_CREATE_DEPLOYMENT`.

### "Show deployment logs for <project>"
`VERCEL_LIST_DEPLOYMENTS` → get latest → `VERCEL_GET_DEPLOYMENT`.

## Constraints
- Confirm project + branch before triggering any deployment.
- Never add env vars without showing key name and asking for value — never log secret values.
