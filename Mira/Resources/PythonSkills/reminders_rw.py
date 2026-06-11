#!/usr/bin/env python3
"""
Read and write Apple Reminders via osascript (AppleScript).
No external deps — stdlib only.

Args JSON (stdin):
  {op: "list_lists"}
      → all reminder lists

  {op: "list", list?: "<name>", include_completed?: false}
      → reminders in a list (default: all lists, incomplete only)

  {op: "add", title: "<text>", list?: "<name>", due?: "<YYYY-MM-DD HH:MM>", notes?: "<text>"}
      → create a new reminder; list defaults to "Reminders"

  {op: "complete", query: "<title fragment>", list?: "<name>"}
      → mark matching reminder(s) as complete

  {op: "delete", query: "<title fragment>", list?: "<name>"}
      → delete matching reminder(s)

  {op: "search", query: "<text>"}
      → reminders whose title or notes contain the query

Output JSON:
  {success, lists?, reminders?, added?, completed_count?, deleted_count?, error?}
  reminder: {id, title, notes, due, completed, list}
"""
import sys, json, subprocess, datetime

def run_script(script: str) -> tuple[str, str]:
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=15)
    return r.stdout.strip(), r.stderr.strip()

def out(data: dict):
    print(json.dumps(data))

# ── list_lists ──────────────────────────────────────────────────────────────

def list_lists():
    script = """
tell application "Reminders"
    set nameList to {}
    repeat with l in lists
        set end of nameList to name of l
    end repeat
    set AppleScript's text item delimiters to "|||"
    set resultStr to nameList as text
    set AppleScript's text item delimiters to ""
    return resultStr
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    names = [n.strip() for n in stdout.split("|||") if n.strip()]
    out({"success": True, "lists": names, "total": len(names)})

# ── list reminders ───────────────────────────────────────────────────────────

def list_reminders(list_name: str | None, include_completed: bool):
    completed_filter = "" if include_completed else "whose completed is false"
    if list_name:
        safe = list_name.replace('"', '\\"')
        scope = f'list "{safe}"'
    else:
        scope = "every list"

    script = f"""
tell application "Reminders"
    set output to {{}}
    if "{list_name or ''}" is not "" then
        set targetLists to {{list "{list_name or ''}"}}
    else
        set targetLists to every list
    end if
    repeat with l in targetLists
        set lname to name of l
        set rems to every reminder of l {completed_filter}
        repeat with r in rems
            set rtitle to name of r
            set rnotes to ""
            try
                set rnotes to body of r
            end try
            set rdue to ""
            try
                set rd to due date of r
                set rdue to (year of rd as text) & "-" & ¬
                    text -2 thru -1 of ("0" & (month of rd as integer)) & "-" & ¬
                    text -2 thru -1 of ("0" & day of rd) & " " & ¬
                    text -2 thru -1 of ("0" & hours of rd) & ":" & ¬
                    text -2 thru -1 of ("0" & minutes of rd)
            end try
            set rc to completed of r as text
            set end of output to (lname & "|||" & rtitle & "|||" & rnotes & "|||" & rdue & "|||" & rc)
        end repeat
    end repeat
    set AppleScript's text item delimiters to "~~~"
    set res to output as text
    set AppleScript's text item delimiters to ""
    return res
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    reminders = []
    for line in stdout.split("~~~"):
        parts = line.split("|||")
        if len(parts) >= 5:
            reminders.append({
                "list":      parts[0].strip(),
                "title":     parts[1].strip(),
                "notes":     parts[2].strip(),
                "due":       parts[3].strip() or None,
                "completed": parts[4].strip() == "true",
            })
    out({"success": True, "reminders": reminders, "total": len(reminders)})

# ── add reminder ─────────────────────────────────────────────────────────────

def add_reminder(title: str, list_name: str, due: str | None, notes: str | None):
    safe_title = title.replace('"', '\\"').replace("'", "\\'")
    safe_list  = (list_name or "Reminders").replace('"', '\\"')
    props = [f'name:"{safe_title}"']
    if due:
        props.append(f'due date:date "{due}"')
    if notes:
        safe_notes = notes.replace('"', '\\"')
        props.append(f'body:"{safe_notes}"')
    props_str = ", ".join(props)

    script = f"""
tell application "Reminders"
    tell list "{safe_list}"
        set r to make new reminder with properties {{{props_str}}}
        return name of r
    end tell
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    out({"success": True, "added": stdout.strip() or title, "list": list_name or "Reminders"})

# ── complete reminder ────────────────────────────────────────────────────────

def complete_reminder(query: str, list_name: str | None):
    safe_q = query.replace('"', '\\"')
    if list_name:
        safe_l = list_name.replace('"', '\\"')
        scope = f'every reminder of list "{safe_l}" whose name contains "{safe_q}"'
    else:
        scope = f'every reminder whose name contains "{safe_q}"'

    script = f"""
tell application "Reminders"
    set targets to {scope}
    set n to count of targets
    repeat with r in targets
        set completed of r to true
    end repeat
    return n as text
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    try:
        count = int(stdout.strip())
    except Exception:
        count = 0
    out({"success": True, "completed_count": count, "query": query})

# ── delete reminder ──────────────────────────────────────────────────────────

def delete_reminder(query: str, list_name: str | None):
    safe_q = query.replace('"', '\\"')
    if list_name:
        safe_l = list_name.replace('"', '\\"')
        scope = f'every reminder of list "{safe_l}" whose name contains "{safe_q}"'
    else:
        scope = f'every reminder whose name contains "{safe_q}"'

    script = f"""
tell application "Reminders"
    set targets to {scope}
    set n to count of targets
    repeat with r in targets
        delete r
    end repeat
    return n as text
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    try:
        count = int(stdout.strip())
    except Exception:
        count = 0
    out({"success": True, "deleted_count": count, "query": query})

# ── search ───────────────────────────────────────────────────────────────────

def search_reminders(query: str):
    safe_q = query.replace('"', '\\"')
    script = f"""
tell application "Reminders"
    set output to {{}}
    repeat with l in lists
        set lname to name of l
        set matches to every reminder of l whose name contains "{safe_q}"
        repeat with r in matches
            set rtitle to name of r
            set rc to completed of r as text
            set rdue to ""
            try
                set rd to due date of r
                set rdue to (year of rd as text) & "-" & ¬
                    text -2 thru -1 of ("0" & (month of rd as integer)) & "-" & ¬
                    text -2 thru -1 of ("0" & day of rd)
            end try
            set end of output to (lname & "|||" & rtitle & "|||" & rdue & "|||" & rc)
        end repeat
    end repeat
    set AppleScript's text item delimiters to "~~~"
    set res to output as text
    set AppleScript's text item delimiters to ""
    return res
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    reminders = []
    for line in stdout.split("~~~"):
        parts = line.split("|||")
        if len(parts) >= 4:
            reminders.append({
                "list":      parts[0].strip(),
                "title":     parts[1].strip(),
                "due":       parts[2].strip() or None,
                "completed": parts[3].strip() == "true",
            })
    out({"success": True, "reminders": reminders, "total": len(reminders)})

# ── main ─────────────────────────────────────────────────────────────────────

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    op = args.get("op", "list")

    try:
        if op == "list_lists":
            list_lists()
        elif op == "list":
            list_reminders(args.get("list"), bool(args.get("include_completed", False)))
        elif op == "add":
            title = args.get("title", "").strip()
            if not title:
                out({"success": False, "error": "title is required for op=add"})
                return
            add_reminder(title, args.get("list", "Reminders"),
                         args.get("due"), args.get("notes"))
        elif op == "complete":
            query = args.get("query", "").strip()
            if not query:
                out({"success": False, "error": "query is required for op=complete"})
                return
            complete_reminder(query, args.get("list"))
        elif op == "delete":
            query = args.get("query", "").strip()
            if not query:
                out({"success": False, "error": "query is required for op=delete"})
                return
            delete_reminder(query, args.get("list"))
        elif op == "search":
            query = args.get("query", "").strip()
            if not query:
                out({"success": False, "error": "query is required for op=search"})
                return
            search_reminders(query)
        else:
            out({"success": False, "error": f"Unknown op: {op}. Use: list_lists, list, add, complete, delete, search"})
    except subprocess.TimeoutExpired:
        out({"success": False, "error": "Timed out waiting for Reminders.app. Is it installed?"})
    except Exception as e:
        out({"success": False, "error": str(e)})

main()
