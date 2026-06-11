# Google Docs
composio_toolkit: GOOGLEDOCS

## When to use
User mentions: Google Doc, document, Docs, write a doc, open a doc, edit a document, create a document, append to doc, read the doc.

## Composio tools (prefix GOOGLEDOCS_)
- `GOOGLEDOCS_GET_DOCUMENT` — read full document content
- `GOOGLEDOCS_CREATE_DOCUMENT` — create a new blank document
- `GOOGLEDOCS_BATCH_UPDATE_DOCUMENT` — insert text, apply formatting, replace content
- `GOOGLEDOCS_SEARCH_DOCUMENTS` — list or search documents in Drive

## Canonical patterns

### "Read my onboarding doc"
`GOOGLEDOCS_SEARCH_DOCUMENTS(q: "onboarding")` → pick best match, `GOOGLEDOCS_GET_DOCUMENT(documentId)` → summarise or quote.

### "Create a document called Meeting Notes - June"
`GOOGLEDOCS_CREATE_DOCUMENT(title: "Meeting Notes - June")` → return the edit URL.

### "Add a section about pricing to my proposal doc"
1. Locate doc with `GOOGLEDOCS_SEARCH_DOCUMENTS`.
2. Confirm insertion point (end, or after named section).
3. `GOOGLEDOCS_BATCH_UPDATE_DOCUMENT` with the new content on approval.

### "Replace the placeholder [COMPANY] with Acme Corp"
`GOOGLEDOCS_BATCH_UPDATE_DOCUMENT` with a `replaceAllText` request.

## Constraints
- Always confirm which document before making any edits.
- Show a preview of changes (before/after snippet) before writing to the document.
- Never replace large sections without confirming the full replacement text.
