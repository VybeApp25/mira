# Netlify
composio_toolkit: NETLIFY

## When to use
User mentions: Netlify, deploy, site, build, domain, environment variable, form, function.

## Composio tools (prefix NETLIFY_)
- `NETLIFY_LIST_SITES` — list user's sites
- `NETLIFY_GET_SITE` — site details, publish URL, deploy settings
- `NETLIFY_LIST_SITE_DEPLOYS` — recent deploys with status
- `NETLIFY_GET_DEPLOY` — deploy details and log
- `NETLIFY_CREATE_SITE_DEPLOY` — trigger deploy (confirm first)
- `NETLIFY_UPDATE_SITE` — update site settings

## Canonical patterns

### "What's the status of my Netlify site?"
`NETLIFY_LIST_SITES` → pick match → `NETLIFY_LIST_SITE_DEPLOYS(count:1)` → report state + url.

### "Trigger a build for <site>"
Confirm site name → `NETLIFY_CREATE_SITE_DEPLOY`.

## Constraints
- Confirm site name before triggering any deploy.
