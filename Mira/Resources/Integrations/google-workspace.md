# Google Workspace

Gmail, Calendar, Drive, Docs, and Sheets via Composio MCP integration.

## Routing

Google Workspace is NOT one monolithic connector. Mira exposes separate integrations and separate Composio toolkits:

| Service | Composio toolkit | Connect via |
|---------|-----------------|-------------|
| Gmail | `gmail` | Settings → Integrations → Gmail |
| Google Calendar | `googlecalendar` | Settings → Integrations → Google Calendar |
| Google Drive | `googledrive` | Settings → Integrations → Google Drive |
| Google Docs | `googledocs` | Settings → Integrations → Google Docs |
| Google Sheets | `googlesheets` | Settings → Integrations → Google Sheets |

**Google Cloud/GCP is not Google Workspace** — use CLI, web, or browser routes for GCP tasks.

## Gmail

Use Composio `gmail` toolkit when connected. Never send without showing a draft summary first.

Draft-first contract:
1. Draft the message
2. Show recipient, subject, body preview to user
3. Wait for explicit "send it" / "yes send" approval
4. Only then call GMAIL_SEND_EMAIL

Key operations:
- Search: `GMAIL_SEARCH_EMAILS` with Gmail query syntax (is:unread, from:, newer_than:, etc.)
- Read: `GMAIL_FETCH_EMAILS`
- Draft: `GMAIL_CREATE_EMAIL_DRAFT`
- Send: `GMAIL_SEND_EMAIL` — always requires user approval first
- Labels: `GMAIL_MODIFY_THREAD_LABELS`
- Reply: `GMAIL_REPLY_TO_THREAD`

If the Gmail connection is missing: "Open Mira Settings → Integrations → connect Gmail"

## Google Calendar

- List events: `GOOGLECALENDAR_LIST_EVENTS`
- Create event: `GOOGLECALENDAR_CREATE_EVENT` — show event summary before creating
- Delete event: always require confirmation
- Always use ISO 8601 with timezone offset (e.g., `2026-03-01T10:00:00-05:00`)

## Google Drive

- Search: `GOOGLEDRIVE_FIND_FILE`
- Read: `GOOGLEDRIVE_GET_FILE_CONTENT`
- Upload: `GOOGLEDRIVE_UPLOAD_FILE`
- Create folder: `GOOGLEDRIVE_CREATE_FOLDER`

## Google Docs

- Read: `GOOGLEDOCS_GET_DOCUMENT`
- Create: `GOOGLEDOCS_CREATE_DOCUMENT`
- Append: `GOOGLEDOCS_UPDATE_DOCUMENT`

## Google Sheets

- Read range: `GOOGLESHEETS_BATCH_GET`
- Write range: `GOOGLESHEETS_BATCH_UPDATE`
- Create spreadsheet: `GOOGLESHEETS_CREATE_SPREADSHEET`
- Append rows: `GOOGLESHEETS_INSERT_ROWS`

## Composio Tool Contract

For any write operation:
1. Use exact tool schema key names (never infer aliases)
2. After write, verify with a structured read-back
3. A `successful: true` response is not enough — confirm the user-visible result
4. For schemas not already visible, call `COMPOSIO_GET_TOOL_SCHEMAS` once

Never run OAuth from inside the agent. If a connection is missing, expired, or lacks permission:
→ "Open Mira Settings → Integrations and connect/reconnect [specific service]"

## Day Planning Pattern

For "what's on my calendar today" or "catch me up on email":
1. `GOOGLECALENDAR_LIST_EVENTS` for today's date range
2. `GMAIL_SEARCH_EMAILS` with `is:unread newer_than:1d`
3. Summarise both in a single concise morning brief
