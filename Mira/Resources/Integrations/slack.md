# Slack
composio_toolkit: SLACK

## When to use
User mentions: Slack, message, channel, DM, send to #channel, post to Slack, notify team, check Slack.

## Composio tools (prefix SLACK_)
- `SLACK_LIST_CHANNELS` — list channels the user belongs to
- `SLACK_SENDS_A_MESSAGE_TO_A_SLACK_CHANNEL` — post to a channel
- `SLACK_SEND_DM_MESSAGE` — send a direct message
- `SLACK_FETCH_CONVERSATION_HISTORY` — read recent messages
- `SLACK_GET_USER_INFO` / `SLACK_LIST_USERS` — look up user IDs

## Canonical patterns

### "Send a message to #general: <text>"
Show message preview, get approval, then `SLACK_SENDS_A_MESSAGE_TO_A_SLACK_CHANNEL`.

### "DM <name> saying <text>"
`SLACK_LIST_USERS` to resolve name → `SLACK_SEND_DM_MESSAGE` after approval.

### "What's in #updates?"
`SLACK_FETCH_CONVERSATION_HISTORY(channel: <id>, limit: 10)` → summarise.

## Constraints
- Always show the exact message text before sending — never send without approval.
- Confirm channel and recipient before any post.
