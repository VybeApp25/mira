# Apple Notes
tools: run_python_skill (full CRUD), run_apple_script (quick ops)

## When to use
User says: note, Notes app, jot down, add to notes, find my note about, open Notes, create a note, search my notes.

## Python skill (preferred — structured JSON responses)

### List folders
`run_python_skill(skill:"notes_rw", args:{op:"list_folders"})`

### List recent notes
`run_python_skill(skill:"notes_rw", args:{op:"list", folder?:"<name>", count?:20})`
Returns: `{success, notes:[{title, folder, modified}], total}`

### Read a note
`run_python_skill(skill:"notes_rw", args:{op:"read", title:"<partial title>"})`
Returns full body text (HTML stripped, capped at 6000 chars).

### Create a note
`run_python_skill(skill:"notes_rw", args:{op:"create", title:"<title>", body:"<text>", folder?:"Notes"})`

### Append to a note
`run_python_skill(skill:"notes_rw", args:{op:"append", title:"<partial title>", text:"<content to add>"})`

### Search notes
`run_python_skill(skill:"notes_rw", args:{op:"search", query:"<text>", count?:10})`
Searches both title and body.

## Canonical patterns

### "Create a note called <title> with <content>"
op:"create" — no confirmation needed.

### "Find my note about <topic>"
op:"search" → list matching titles → offer to read the best match.

### "Add <text> to my <title> note"
op:"append".

### "What are in my notes?"
op:"list", count:10 → titles + modification dates.

## Constraints
- Requires Automation permission for Notes.app.
- Large note bodies are capped at 6000 chars in the read op — warn user if truncated.
- If success is false, show the error string to the user.
