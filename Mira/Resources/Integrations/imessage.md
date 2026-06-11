# iMessage
tool: run_apple_script (built-in)

## When to use
User says: iMessage, text, send a message to, message <name>, SMS.

## AppleScript patterns

### Send a message
```applescript
tell application "Messages"
  set targetBuddy to "<phone or email>"
  set targetService to 1st service whose service type = iMessage
  send "<message text>" to buddy targetBuddy of targetService
end tell
```

### Read recent messages from a contact
```applescript
tell application "Messages"
  set theChats to (every chat whose name contains "<name>")
  -- list recent messages from first matching chat
end tell
```

## Canonical patterns

### "Send <name> a message saying <text>"
1. Show: "Send to <name>: '<text>'" — get explicit approval.
2. Resolve phone/email for the contact if needed.
3. `run_apple_script` with the send snippet above.

## Constraints
- ALWAYS confirm recipient and exact message text before sending — iMessage is irreversible.
- Requires Accessibility + Automation permission for Messages.
