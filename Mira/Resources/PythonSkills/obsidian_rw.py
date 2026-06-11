#!/usr/bin/env python3
"""Obsidian vault skill — no external deps (pathlib + re only)."""
import json, sys, pathlib, re, datetime

def find_vault(vault_path=None):
    if vault_path:
        p = pathlib.Path(vault_path).expanduser()
        if p.is_dir():
            return p
    # Common default locations
    for candidate in [
        "~/Documents/Obsidian", "~/Obsidian", "~/Documents/Notes",
        "~/Desktop/Obsidian", "~/Library/Mobile Documents/iCloud~md~obsidian/Documents",
    ]:
        p = pathlib.Path(candidate).expanduser()
        if p.is_dir():
            md_files = list(p.rglob("*.md"))
            if md_files:
                return p
    return None

def strip_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            return text[end + 4:].lstrip()
    return text

def extract_frontmatter(text):
    meta = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            block = text[4:end]
            for line in block.splitlines():
                if ":" in line:
                    k, _, v = line.partition(":")
                    meta[k.strip()] = v.strip()
    return meta

def extract_wikilinks(text):
    return re.findall(r'\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]', text)

def extract_tags(text):
    return list(set(re.findall(r'(?:^|\s)#([a-zA-Z0-9_/-]+)', text)))

def run(args):
    op        = args.get("op", "list_vault")
    vault_dir = args.get("vault_path")
    vault     = find_vault(vault_dir)

    if vault is None:
        return {"success": False, "error": "No Obsidian vault found. Pass vault_path:/absolute/path/to/vault."}

    # ── list_vault ────────────────────────────────────────────────────────────
    if op == "list_vault":
        notes = []
        for f in sorted(vault.rglob("*.md")):
            rel = str(f.relative_to(vault))
            stat = f.stat()
            notes.append({"path": rel, "name": f.stem,
                          "modified": datetime.datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds")})
        limit = int(args.get("limit", 100))
        return {"success": True, "vault": str(vault), "notes": notes[:limit], "total": len(notes)}

    # ── read ──────────────────────────────────────────────────────────────────
    if op == "read":
        title = args.get("title", "")
        matches = [f for f in vault.rglob("*.md") if title.lower() in f.stem.lower()]
        if not matches:
            return {"success": False, "error": f"No note found matching '{title}'"}
        f = matches[0]
        raw = f.read_text(encoding="utf-8", errors="replace")
        body = strip_frontmatter(raw)
        meta = extract_frontmatter(raw)
        links = extract_wikilinks(raw)
        tags  = extract_tags(raw)
        cap   = int(args.get("max_chars", 8000))
        return {
            "success": True, "path": str(f.relative_to(vault)),
            "title": f.stem, "body": body[:cap],
            "truncated": len(body) > cap, "meta": meta,
            "wikilinks": links, "tags": tags,
        }

    # ── create ────────────────────────────────────────────────────────────────
    if op == "create":
        title   = args.get("title", "Untitled")
        body    = args.get("body", "")
        folder  = args.get("folder", "")
        tags    = args.get("tags", [])
        target  = vault / folder / f"{title}.md" if folder else vault / f"{title}.md"
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and not args.get("overwrite"):
            return {"success": False, "error": f"Note already exists: {title}. Pass overwrite:true to replace."}
        tag_line = ""
        if tags:
            tag_line = "tags: [" + ", ".join(tags) + "]\n"
        now = datetime.datetime.now().isoformat(timespec="seconds")
        frontmatter = f"---\ncreated: {now}\n{tag_line}---\n\n"
        target.write_text(frontmatter + body, encoding="utf-8")
        return {"success": True, "path": str(target.relative_to(vault)), "title": title}

    # ── append ────────────────────────────────────────────────────────────────
    if op == "append":
        title = args.get("title", "")
        text  = args.get("text", "")
        matches = [f for f in vault.rglob("*.md") if title.lower() in f.stem.lower()]
        if not matches:
            return {"success": False, "error": f"No note found matching '{title}'"}
        f = matches[0]
        existing = f.read_text(encoding="utf-8", errors="replace")
        f.write_text(existing.rstrip() + "\n\n" + text + "\n", encoding="utf-8")
        return {"success": True, "path": str(f.relative_to(vault)), "title": f.stem, "appended_chars": len(text)}

    # ── search ────────────────────────────────────────────────────────────────
    if op == "search":
        query   = args.get("query", "").lower()
        limit   = int(args.get("limit", 10))
        results = []
        for f in vault.rglob("*.md"):
            raw = f.read_text(encoding="utf-8", errors="replace")
            body = strip_frontmatter(raw)
            if query in f.stem.lower() or query in body.lower():
                # Find first matching snippet
                idx = body.lower().find(query)
                snippet = body[max(0, idx-60):idx+120].strip() if idx >= 0 else body[:120]
                results.append({
                    "title": f.stem,
                    "path": str(f.relative_to(vault)),
                    "snippet": snippet,
                    "title_match": query in f.stem.lower(),
                })
                if len(results) >= limit:
                    break
        return {"success": True, "query": query, "results": results, "total": len(results)}

    # ── wikilinks ─────────────────────────────────────────────────────────────
    if op == "wikilinks":
        title = args.get("title", "")
        matches = [f for f in vault.rglob("*.md") if title.lower() in f.stem.lower()]
        if not matches:
            return {"success": False, "error": f"No note found matching '{title}'"}
        f = matches[0]
        raw = f.read_text(encoding="utf-8", errors="replace")
        links = extract_wikilinks(raw)
        return {"success": True, "title": f.stem, "wikilinks": links, "total": len(links)}

    return {"success": False, "error": f"Unknown op: {op}. Valid: list_vault, read, create, append, search, wikilinks"}

if __name__ == "__main__":
    args = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
    print(json.dumps(run(args)))
