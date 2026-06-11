# Apple Notes
tool: run_apple_script / run_shell_command (built-in)

## When to use
User says: note, Notes app, jot down, add to notes, find my note about, open Notes.

## AppleScript patterns

### Create a note
```applescript
tell application "Notes"
  tell account "iCloud"
    make new note at folder "Notes" with properties {name:"<title>", body:"<body>"}
  end tell
end tell
```

### Search notes
```applescript
tell application "Notes"
  set matchingNotes to every note whose name contains "<query>" or body contains "<query>"
  repeat with n in matchingNotes
    get name of n
  end repeat
end tell
```

### Append to an existing note
```applescript
tell application "Notes"
  set targetNote to first note whose name is "<title>"
  set body of targetNote to (body of targetNote) & "<additional text>"
end tell
```

## Canonical patterns

### "Create a note called <title> with <content>"
`run_apple_script` with create snippet — no confirmation needed for creation.

### "Find my note about <topic>"
Search AppleScript → return matching note names.

### "Add <text> to my <title> note"
Search for note by name → append body.

## Constraints
- Notes requires Automation permission for the Notes app.
- Large note bodies may be truncated in AppleScript results — read in chunks if needed.
