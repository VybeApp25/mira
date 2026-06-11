# Gmail
composio_toolkit: GMAIL

## When to use
User mentions: email, inbox, Gmail, unread, send, reply, draft, forward, label, archive, search mail, compose.

## Composio tools (prefix GMAIL_)
- `GMAIL_LIST_THREADS` / `GMAIL_GET_THREAD` — read threads
- `GMAIL_LIST_MESSAGES` / `GMAIL_GET_MESSAGE` — read individual messages
- `GMAIL_SEND_MESSAGE` — send (always draft-first, confirm before sending)
- `GMAIL_CREATE_DRAFT` — create draft without sending
- `GMAIL_REPLY_TO_THREAD` — reply (confirm before sending)
- `GMAIL_MODIFY_MESSAGE` — archive, label, mark read/unread
- `GMAIL_SEARCH_PEOPLE` — find contacts

## Canonical patterns

### "What's in my inbox?" / "Show unread emails"
`GMAIL_LIST_MESSAGES(labelIds: ["INBOX", "UNREAD"], maxResults: 10)` → summarise sender, subject, snippet.

### "Send an email to <name> about <topic>"
1. Draft body, show preview with to/subject/body.
2. Ask for explicit send approval.
3. Only then: `GMAIL_SEND_MESSAGE`.

### "Reply to the email from <name>"
1. Fetch the thread with `GMAIL_GET_THREAD`.
2. Draft reply, show preview.
3. Confirm before `GMAIL_REPLY_TO_THREAD`.

### "Archive emails from <sender>"
`GMAIL_MODIFY_MESSAGE(removeLabelIds: ["INBOX"])` for each — confirm count first.

## Constraints
- NEVER send without explicit user approval of the exact to/subject/body.
- Draft-first always: create the draft content and show it before any send call.
- If send permission is missing: "Your Gmail connection needs send permission — reconnect in Mira Settings → Integrations."
