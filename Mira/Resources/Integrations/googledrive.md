# Google Drive
composio_toolkit: GOOGLEDRIVE

## When to use
User mentions: Google Drive, Drive, upload to Drive, share a file, Drive link, Drive folder, find in Drive, Drive storage, save to Drive.

## Composio tools (prefix GOOGLEDRIVE_)
- `GOOGLEDRIVE_LIST_DRIVE_FILES` — list or search files and folders
- `GOOGLEDRIVE_GET_FILE_INFO` — metadata for a file (name, type, owner, modified)
- `GOOGLEDRIVE_DOWNLOAD_FILE` — download file content
- `GOOGLEDRIVE_UPLOAD_FILE` — upload a local file to Drive
- `GOOGLEDRIVE_CREATE_FOLDER` — create a new folder
- `GOOGLEDRIVE_DELETE_FILE` — move to trash (confirm before)
- `GOOGLEDRIVE_SHARE_FILE` — set sharing permissions
- `GOOGLEDRIVE_MOVE_FILE` — move file to a different folder
- `GOOGLEDRIVE_COPY_FILE` — duplicate a file

## Canonical patterns

### "Find my presentation about Q3"
`GOOGLEDRIVE_LIST_DRIVE_FILES(q: "name contains 'Q3' and mimeType contains 'presentation'")` → list matches with name + last-modified.

### "Share the project brief with alex@example.com"
1. Locate the file with `GOOGLEDRIVE_LIST_DRIVE_FILES`.
2. Confirm which file and permission level (viewer/commenter/editor).
3. `GOOGLEDRIVE_SHARE_FILE` on approval.

### "Upload this file to my Drive"
`GOOGLEDRIVE_UPLOAD_FILE(name, content, mimeType)` — confirm destination folder first.

### "Create a folder called Marketing Assets"
`GOOGLEDRIVE_CREATE_FOLDER(name: "Marketing Assets")`.

## Constraints
- Never delete without explicit confirmation naming the file.
- Confirm share recipients and permission levels before executing.
- When listing many results, summarise (name, type, last modified) rather than dumping raw JSON.
