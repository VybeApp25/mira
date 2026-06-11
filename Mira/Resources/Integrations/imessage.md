# iMessage
tools: run_python_skill (read), run_apple_script (send)

## When to use
User says: iMessage, text, send a message to, message <name>, SMS, read my messages, what did <name> say, search my messages.

## Reading messages (CLI — queries ~/Library/Messages/chat.db)

Requires Mira to have **Full Disk Access**: System Settings → Privacy & Security → Full Disk Access → enable Mira.
If the skill returns a permission error, inform the user and stop.

### Recent messages (last 20)
`run_python_skill(skill:"imessage_read", args:{op:"recent", count:20})`

### Thread with a contact
`run_python_skill(skill:"imessage_read", args:{op:"thread", contact:"<name or phone or email>", count:30})`
Returns messages in chronological order (oldest first).

### Search message history
`run_python_skill(skill:"imessage_read", args:{op:"search", query:"<search text>", count:20})`

### List recent contacts
`run_python_skill(skill:"imessage_read", args:{op:"contacts", count:20})`

All read ops return JSON: `{success, messages:[{text, sender, date_iso, is_from_me, service}], total}`.
Present messages in a readable list: sender, time, and message text. Do not dump raw JSON.

## Sending messages (AppleScript)

### Send a message
```applescript
tell application "Messages"
  set targetBuddy to "<phone or email>"
  set targetService to 1st service whose service type = iMessage
  send "<message text>" to buddy targetBuddy of targetService
end tell
```
Use `run_apple_script` with the snippet above.

## Canonical patterns

### "What did <name> say recently?"
1. `run_python_skill` op:"thread", contact:"<name>".
2. Summarise the last few messages.

### "Search my messages for <topic>"
`run_python_skill` op:"search", query:"<topic>".

### "Show my recent messages"
`run_python_skill` op:"recent", count:10 → list sender + time + preview.

### "Send <name> a message saying <text>"
1. Show: "Send to <name>: '<text>'" — get explicit approval.
2. `run_apple_script` with the send snippet.

## Constraints
- ALWAYS confirm recipient and exact message text before sending — iMessage is irreversible.
- For reads: if success is false, show the error.error string to the user — do not retry silently.
- Never expose raw phone numbers in responses unless the user asked for them.
