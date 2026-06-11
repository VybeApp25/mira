#!/usr/bin/env python3
"""
Query the iMessage SQLite database (read-only).
Requires Full Disk Access for Mira: System Settings → Privacy & Security → Full Disk Access.

Args JSON (stdin):
  {op: "recent",   count?: 20}
      → latest N text messages across all conversations

  {op: "thread",   contact: "<name|phone|email>",  count?: 30}
      → messages in the conversation with that contact
        (matches handle.id, chat.display_name, or chat.chat_identifier)

  {op: "search",   query: "<text>",  count?: 20}
      → messages containing the query string

  {op: "contacts", count?: 20}
      → most-recently-active contacts with last message time

Output JSON: {success, messages?, contacts?, total?, error?}
  message object: {text, sender, date_iso, is_from_me, service}
  contact object: {id, last_message_iso, message_count}
"""
import sys, json, os, sqlite3, datetime

DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")
# Mac absolute reference date offset (seconds between 1970-01-01 and 2001-01-01)
MAC_EPOCH_OFFSET = 978307200

def mac_ts_to_iso(mac_ns: int) -> str:
    if not mac_ns:
        return ""
    try:
        unix_ts = mac_ns / 1e9 + MAC_EPOCH_OFFSET
        return datetime.datetime.fromtimestamp(unix_ts, tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        return ""

def open_db() -> sqlite3.Connection:
    # Open read-only via URI; works even when Messages.app has the DB open.
    return sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)

def row_to_msg(row, col_names: list) -> dict:
    r = dict(zip(col_names, row))
    return {
        "text":        (r.get("text") or "").strip(),
        "sender":      "Me" if r.get("is_from_me") else (r.get("handle_id") or "Unknown"),
        "date_iso":    mac_ts_to_iso(r.get("date") or 0),
        "is_from_me":  bool(r.get("is_from_me")),
        "service":     r.get("service") or "iMessage",
    }

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    op    = args.get("op", "recent")
    count = max(1, min(int(args.get("count", 20)), 100))

    # Permission check
    if not os.path.exists(DB_PATH):
        print(json.dumps({"success": False,
                          "error": f"iMessage database not found at {DB_PATH}. "
                                   "Ensure Messages has been used at least once."}))
        return

    try:
        db = open_db()
    except Exception as e:
        print(json.dumps({"success": False,
                          "error": f"Cannot open iMessage database: {e}. "
                                   "Mira needs Full Disk Access: System Settings → Privacy & Security → Full Disk Access."}))
        return

    try:
        if op == "recent":
            sql = """
                SELECT m.text, m.date, m.is_from_me, h.id AS handle_id, m.service
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.text IS NOT NULL AND m.text != '' AND m.item_type = 0
                ORDER BY m.date DESC
                LIMIT ?
            """
            cur = db.execute(sql, (count,))
            cols = [d[0] for d in cur.description]
            messages = [row_to_msg(r, cols) for r in cur.fetchall()]
            print(json.dumps({"success": True, "messages": messages, "total": len(messages)}))

        elif op == "thread":
            contact = args.get("contact", "")
            if not contact:
                print(json.dumps({"success": False, "error": "contact is required for op=thread"}))
                return
            like = f"%{contact}%"
            sql = """
                SELECT DISTINCT m.text, m.date, m.is_from_me, h.id AS handle_id, m.service
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE m.text IS NOT NULL AND m.text != '' AND m.item_type = 0
                  AND (h.id LIKE ? OR c.display_name LIKE ? OR c.chat_identifier LIKE ?)
                ORDER BY m.date DESC
                LIMIT ?
            """
            cur = db.execute(sql, (like, like, like, count))
            cols = [d[0] for d in cur.description]
            messages = [row_to_msg(r, cols) for r in cur.fetchall()]
            if not messages:
                print(json.dumps({"success": False,
                                  "error": f"No messages found matching contact '{contact}'"}))
            else:
                # Return chronological order (oldest first)
                messages.reverse()
                print(json.dumps({"success": True, "messages": messages, "total": len(messages)}))

        elif op == "search":
            query = args.get("query", "")
            if not query:
                print(json.dumps({"success": False, "error": "query is required for op=search"}))
                return
            like = f"%{query}%"
            sql = """
                SELECT m.text, m.date, m.is_from_me, h.id AS handle_id, m.service
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.text LIKE ? AND m.item_type = 0
                ORDER BY m.date DESC
                LIMIT ?
            """
            cur = db.execute(sql, (like, count))
            cols = [d[0] for d in cur.description]
            messages = [row_to_msg(r, cols) for r in cur.fetchall()]
            print(json.dumps({"success": True, "messages": messages, "total": len(messages)}))

        elif op == "contacts":
            sql = """
                SELECT h.id, MAX(m.date) AS last_date, COUNT(m.ROWID) AS msg_count
                FROM handle h
                JOIN message m ON m.handle_id = h.ROWID
                WHERE m.text IS NOT NULL AND m.item_type = 0
                GROUP BY h.id
                ORDER BY last_date DESC
                LIMIT ?
            """
            cur = db.execute(sql, (count,))
            contacts = [
                {
                    "id":               row[0],
                    "last_message_iso": mac_ts_to_iso(row[1] or 0),
                    "message_count":    row[2],
                }
                for row in cur.fetchall()
            ]
            print(json.dumps({"success": True, "contacts": contacts, "total": len(contacts)}))

        else:
            print(json.dumps({"success": False, "error": f"Unknown op: {op}. Use: recent, thread, search, contacts"}))

    except sqlite3.OperationalError as e:
        if "unable to open" in str(e).lower() or "permission" in str(e).lower():
            print(json.dumps({"success": False,
                              "error": "Permission denied reading iMessage database. "
                                       "Grant Mira Full Disk Access: System Settings → Privacy & Security → Full Disk Access."}))
        else:
            print(json.dumps({"success": False, "error": str(e)}))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
    finally:
        try:
            db.close()
        except Exception:
            pass

main()
