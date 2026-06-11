# Notion
composio_toolkit: NOTION

## When to use
User mentions: Notion, page, database, note, doc, wiki, block, workspace, entry, table row.

## Composio tools (prefix NOTION_)
- `NOTION_SEARCH` — search pages and databases
- `NOTION_RETRIEVE_A_PAGE` — get page content
- `NOTION_CREATE_PAGE` — create a new page
- `NOTION_UPDATE_PAGE` — update page properties
- `NOTION_APPEND_BLOCK_CHILDREN` — append content blocks to a page
- `NOTION_RETRIEVE_BLOCK_CHILDREN` — read page content
- `NOTION_CREATE_DATABASE_ITEM` — add a row to a database
- `NOTION_QUERY_A_DATABASE` — filter/sort database rows
- `NOTION_CREATE_FILE_UPLOAD` + `NOTION_SEND_FILE_UPLOAD` — attach local files

## Canonical patterns

### "Find my <topic> page in Notion"
`NOTION_SEARCH(query: "<topic>")` → return matching page titles and IDs.

### "Create a Notion page titled <title>"
Confirm parent location if ambiguous, then `NOTION_CREATE_PAGE`.

### "Add <item> to my <database> database"
`NOTION_SEARCH(query: "<database>")` to get DB ID → `NOTION_CREATE_DATABASE_ITEM`.

### Attaching a local file
`NOTION_CREATE_FILE_UPLOAD` → `NOTION_SEND_FILE_UPLOAD` → attach `file_upload` ID.
Never use `NOTION_APPEND_BLOCK_CHILDREN` with a local file path — use the upload flow.

## Constraints
- Confirm before creating or updating pages when the user hasn't specified exact content.
- Local paths (/tmp, ~/Desktop, etc.) are not public URLs — use the upload tools.
