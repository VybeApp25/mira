#!/usr/bin/env python3
"""
Read and write Apple Notes via osascript (AppleScript).
No external deps — stdlib only.

Args JSON (stdin):
  {op: "list_folders"}
      → all Note folders/accounts

  {op: "list", folder?: "<name>", count?: 20}
      → recent notes (title, folder, modified date)

  {op: "read", title: "<exact or partial title>"}
      → full body of first matching note

  {op: "create", title: "<title>", body: "<text>", folder?: "<name>"}
      → create a new note; folder defaults to "Notes"

  {op: "append", title: "<partial title>", text: "<text to append>"}
      → append text to the first matching note

  {op: "search", query: "<text>", count?: 10}
      → notes whose title or body contains the query

Output JSON:
  {success, folders?, notes?, note?, created?, appended_to?, error?}
  note object: {title, folder, modified, body?}
"""
import sys, json, subprocess

def run_script(script: str) -> tuple[str, str]:
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
    return r.stdout.strip(), r.stderr.strip()

def out(data: dict):
    print(json.dumps(data))

SEP = "|||"
ROW = "~~~"

# ── list_folders ─────────────────────────────────────────────────────────────

def list_folders():
    script = """
tell application "Notes"
    set result to {}
    repeat with a in accounts
        repeat with f in folders of a
            set end of result to (name of a & "|||" & name of f)
        end repeat
    end repeat
    set AppleScript's text item delimiters to "~~~"
    set r to result as text
    set AppleScript's text item delimiters to ""
    return r
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    folders = []
    for line in stdout.split(ROW):
        parts = line.split(SEP)
        if len(parts) >= 2:
            folders.append({"account": parts[0].strip(), "folder": parts[1].strip()})
    out({"success": True, "folders": folders, "total": len(folders)})

# ── list notes ───────────────────────────────────────────────────────────────

def list_notes(folder: str | None, count: int):
    if folder:
        safe = folder.replace('"', '\\"')
        scope = f'notes of folder "{safe}"'
    else:
        scope = "notes"

    script = f"""
tell application "Notes"
    set allNotes to {scope}
    set sortedNotes to allNotes -- Notes are already sorted newest first
    set output to {{}}
    set n to count of sortedNotes
    if n > {count} then set n to {count}
    repeat with i from 1 to n
        set nt to item i of sortedNotes
        set ntitle to name of nt
        set nmod to modification date of nt
        set nmodStr to (year of nmod as text) & "-" & ¬
            text -2 thru -1 of ("0" & (month of nmod as integer)) & "-" & ¬
            text -2 thru -1 of ("0" & day of nmod)
        set nfolder to ""
        try
            set nfolder to name of container of nt
        end try
        set end of output to (ntitle & "|||" & nfolder & "|||" & nmodStr)
    end repeat
    set AppleScript's text item delimiters to "~~~"
    set r to output as text
    set AppleScript's text item delimiters to ""
    return r
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    notes = []
    for line in stdout.split(ROW):
        parts = line.split(SEP)
        if len(parts) >= 3 and parts[0].strip():
            notes.append({
                "title":    parts[0].strip(),
                "folder":   parts[1].strip(),
                "modified": parts[2].strip(),
            })
    out({"success": True, "notes": notes, "total": len(notes)})

# ── read note ────────────────────────────────────────────────────────────────

def read_note(title: str):
    safe = title.replace('"', '\\"')
    script = f"""
tell application "Notes"
    set matches to notes whose name contains "{safe}"
    if (count of matches) is 0 then return "NOT_FOUND"
    set nt to item 1 of matches
    set nbody to body of nt
    -- Strip basic HTML tags for readable output
    set ntitle to name of nt
    set nfolder to ""
    try
        set nfolder to name of container of nt
    end try
    return ntitle & "|||" & nfolder & "|||" & nbody
end tell
"""
    stdout, stderr = run_script(script)
    if stdout == "NOT_FOUND":
        out({"success": False, "error": f"No note found matching '{title}'"})
        return
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    parts = stdout.split(SEP, 2)
    body_raw = parts[2] if len(parts) >= 3 else ""
    # Strip HTML tags naively
    import re
    body_clean = re.sub(r'<[^>]+>', '', body_raw).strip()
    body_clean = re.sub(r'\n{3,}', '\n\n', body_clean)
    out({
        "success": True,
        "note": {
            "title":  parts[0].strip() if parts else title,
            "folder": parts[1].strip() if len(parts) > 1 else "",
            "body":   body_clean[:6000],   # cap at 6000 chars
        }
    })

# ── create note ──────────────────────────────────────────────────────────────

def create_note(title: str, body: str, folder: str | None):
    safe_title  = title.replace('"', '\\"').replace("\\", "\\\\")
    safe_body   = body.replace("\\", "\\\\").replace('"', '\\"')
    safe_folder = (folder or "Notes").replace('"', '\\"')

    script = f"""
tell application "Notes"
    tell account "iCloud"
        set f to first folder whose name is "{safe_folder}"
        make new note at f with properties {{name:"{safe_title}", body:"{safe_body}"}}
        return name of result
    end tell
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and "error" in stderr.lower() and not stdout:
        # Fallback: no folder specified
        script2 = f"""
tell application "Notes"
    make new note with properties {{name:"{safe_title}", body:"{safe_body}"}}
    return name of result
end tell
"""
        stdout, stderr = run_script(script2)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    out({"success": True, "created": stdout.strip() or title, "folder": folder or "Notes"})

# ── append note ──────────────────────────────────────────────────────────────

def append_note(title: str, text: str):
    safe_title = title.replace('"', '\\"')
    safe_text  = text.replace("\\", "\\\\").replace('"', '\\"')

    script = f"""
tell application "Notes"
    set matches to notes whose name contains "{safe_title}"
    if (count of matches) is 0 then return "NOT_FOUND"
    set nt to item 1 of matches
    set body of nt to (body of nt) & "<br>" & "{safe_text}"
    return name of nt
end tell
"""
    stdout, stderr = run_script(script)
    if stdout == "NOT_FOUND":
        out({"success": False, "error": f"No note found matching '{title}'"})
        return
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    out({"success": True, "appended_to": stdout.strip() or title})

# ── search notes ─────────────────────────────────────────────────────────────

def search_notes(query: str, count: int):
    safe_q = query.replace('"', '\\"')
    script = f"""
tell application "Notes"
    set matches to notes whose name contains "{safe_q}" or body contains "{safe_q}"
    set output to {{}}
    set n to count of matches
    if n > {count} then set n to {count}
    repeat with i from 1 to n
        set nt to item i of matches
        set ntitle to name of nt
        set nmod to modification date of nt
        set nmodStr to (year of nmod as text) & "-" & ¬
            text -2 thru -1 of ("0" & (month of nmod as integer)) & "-" & ¬
            text -2 thru -1 of ("0" & day of nmod)
        set nfolder to ""
        try
            set nfolder to name of container of nt
        end try
        set end of output to (ntitle & "|||" & nfolder & "|||" & nmodStr)
    end repeat
    set AppleScript's text item delimiters to "~~~"
    set r to output as text
    set AppleScript's text item delimiters to ""
    return r
end tell
"""
    stdout, stderr = run_script(script)
    if stderr and not stdout:
        out({"success": False, "error": stderr})
        return
    notes = []
    for line in stdout.split(ROW):
        parts = line.split(SEP)
        if len(parts) >= 3 and parts[0].strip():
            notes.append({
                "title":    parts[0].strip(),
                "folder":   parts[1].strip(),
                "modified": parts[2].strip(),
            })
    out({"success": True, "notes": notes, "total": len(notes)})

# ── main ─────────────────────────────────────────────────────────────────────

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    op = args.get("op", "list")

    try:
        if op == "list_folders":
            list_folders()
        elif op == "list":
            list_notes(args.get("folder"), int(args.get("count", 20)))
        elif op == "read":
            title = args.get("title", "").strip()
            if not title:
                out({"success": False, "error": "title is required for op=read"})
                return
            read_note(title)
        elif op == "create":
            title = args.get("title", "").strip()
            body  = args.get("body", "").strip()
            if not title:
                out({"success": False, "error": "title is required for op=create"})
                return
            create_note(title, body, args.get("folder"))
        elif op == "append":
            title = args.get("title", "").strip()
            text  = args.get("text", "").strip()
            if not title or not text:
                out({"success": False, "error": "title and text are required for op=append"})
                return
            append_note(title, text)
        elif op == "search":
            query = args.get("query", "").strip()
            if not query:
                out({"success": False, "error": "query is required for op=search"})
                return
            search_notes(query, int(args.get("count", 10)))
        else:
            out({"success": False, "error": f"Unknown op: {op}. Use: list_folders, list, read, create, append, search"})
    except subprocess.TimeoutExpired:
        out({"success": False, "error": "Timed out waiting for Notes.app."})
    except Exception as e:
        out({"success": False, "error": str(e)})

main()
