# Apple Reminders
tools: run_python_skill (full CRUD), run_apple_script (quick add)

## When to use
User says: reminder, remind me, to-do, task, due date, Reminders app, what are my reminders, add to my list.

## Python skill (preferred — structured JSON responses)

### List all reminder lists
`run_python_skill(skill:"reminders_rw", args:{op:"list_lists"})`

### List reminders
`run_python_skill(skill:"reminders_rw", args:{op:"list", list?:"<name>", include_completed?:false})`
Returns: `{success, reminders:[{title, list, due, notes, completed}], total}`

### Add a reminder
`run_python_skill(skill:"reminders_rw", args:{op:"add", title:"<text>", list?:"Reminders", due?:"YYYY-MM-DD HH:MM", notes?:"<text>"})`
Omit `due` if no time specified. Confirm with user before adding if any ambiguity.

### Complete a reminder
`run_python_skill(skill:"reminders_rw", args:{op:"complete", query:"<title fragment>", list?:"<name>"})`

### Delete a reminder
`run_python_skill(skill:"reminders_rw", args:{op:"delete", query:"<title fragment>"})`
**Always confirm before deleting.**

### Search reminders
`run_python_skill(skill:"reminders_rw", args:{op:"search", query:"<text>"})`

## Canonical patterns

### "Remind me to <task> at <time>"
Parse time → `run_python_skill` op:"add" with due date. Confirm: "Add reminder: '<task>' due <time>?"

### "What are my reminders?"
`run_python_skill` op:"list" → group by list, show due dates.

### "Mark <task> as done"
`run_python_skill` op:"complete", query:"<task>" → report how many were completed.

## Constraints
- Requires Automation permission for Reminders.app.
- Confirm before deleting — irreversible.
- If success is false, show the error string to the user.
