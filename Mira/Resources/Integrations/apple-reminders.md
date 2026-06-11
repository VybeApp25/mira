# Apple Reminders
tool: run_apple_script (built-in)

## When to use
User says: reminder, remind me, to-do, task, due date, Reminders app.

## AppleScript patterns

### Add a reminder
```applescript
tell application "Reminders"
  tell list "Reminders"
    make new reminder with properties {name:"<text>", due date:date "<datetime>"}
  end tell
end tell
```

### List incomplete reminders
```applescript
tell application "Reminders"
  set incompleteReminders to every reminder whose completed is false
  repeat with r in incompleteReminders
    get {name of r, due date of r}
  end repeat
end tell
```

### Complete a reminder
```applescript
tell application "Reminders"
  set targetReminder to first reminder whose name contains "<query>"
  set completed of targetReminder to true
end tell
```

## Canonical patterns

### "Remind me to <task> at <time>"
`run_apple_script` with add snippet — confirm time before creating.

### "What are my reminders?"
List incomplete reminders, group by due date.

### "Mark <task> as done"
Search by name → set completed = true — confirm which reminder.

## Constraints
- Requires Automation permission for Reminders app.
- Omit `due date` property if no time specified.
