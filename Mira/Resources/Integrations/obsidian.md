# Obsidian Vault
tool: run_python_skill

## When to use
User says: Obsidian, vault, my notes, note, wikilink, [[, markdown notes, open vault, search vault.

## Ops

### List vault notes
`run_python_skill(skill:"obsidian_rw", args:{op:"list_vault", vault_path?:"<abs>", limit?:50})`
Returns: `{success, vault, notes:[{path, name, modified}], total}`

### Read a note
`run_python_skill(skill:"obsidian_rw", args:{op:"read", title:"<partial title>", vault_path?:"<abs>"})`
Returns full body (Markdown), frontmatter metadata, wikilinks, and tags.

### Create a note
`run_python_skill(skill:"obsidian_rw", args:{op:"create", title:"<title>", body:"<markdown>", folder?:"<subfolder>", tags?:["tag1","tag2"], vault_path?:"<abs>"})`
Adds auto frontmatter with `created` timestamp.

### Append to a note
`run_python_skill(skill:"obsidian_rw", args:{op:"append", title:"<partial title>", text:"<content>", vault_path?:"<abs>"})`

### Search vault
`run_python_skill(skill:"obsidian_rw", args:{op:"search", query:"<text>", vault_path?:"<abs>", limit?:10})`
Searches title and body; returns matching snippets.

### List wikilinks
`run_python_skill(skill:"obsidian_rw", args:{op:"wikilinks", title:"<partial title>", vault_path?:"<abs>"})`

## Canonical patterns

### "Open my Obsidian note on <topic>"
op:"search" → list matches → op:"read" best match.

### "Create a note called <title>"
op:"create" — title + body from conversation context.

### "Add <text> to my <title> note"
op:"append".

## Constraints
- Auto-detects vault from ~/Documents/Obsidian, ~/Obsidian, iCloud Drive (iCloud~md~obsidian).
- If vault not found, ask user for the vault path.
- Note body capped at 8000 chars in read op — warn if truncated.
