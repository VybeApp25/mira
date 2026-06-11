# Google Sheets
composio_toolkit: GOOGLESHEETS

## When to use
User mentions: Google Sheet, spreadsheet, Sheets, read a spreadsheet, update a sheet, add a row, chart, formula, csv to Sheets, export Sheets.

## Composio tools (prefix GOOGLESHEETS_)
- `GOOGLESHEETS_GET_VALUES` — read a range (e.g. `Sheet1!A1:D20`)
- `GOOGLESHEETS_BATCH_GET` — read multiple ranges in one call
- `GOOGLESHEETS_UPDATE_VALUES` — write values to a range
- `GOOGLESHEETS_APPEND_VALUES` — append rows at the bottom of a range
- `GOOGLESHEETS_CLEAR_VALUES` — clear a range (confirm before)
- `GOOGLESHEETS_CREATE_SPREADSHEET` — create a new spreadsheet
- `GOOGLESHEETS_COPY_SHEET` — duplicate a sheet within a spreadsheet
- `GOOGLESHEETS_BATCH_UPDATE` — structural changes: add sheet, format cells, add chart

## Canonical patterns

### "What's in my pipeline tracker?"
1. Find spreadsheet via `GOOGLEDRIVE_LIST_DRIVE_FILES(q: "name contains 'pipeline' and mimeType='spreadsheet'")`.
2. `GOOGLESHEETS_GET_VALUES(range: "Sheet1!A1:Z50")` → parse headers + rows, present as table.

### "Add a row: deal with ACME, $50k, closing June 30"
1. Confirm spreadsheet and sheet tab.
2. `GOOGLESHEETS_APPEND_VALUES(range: "Sheet1", values: [[...]])`.

### "Create a spreadsheet for my weekly budget"
`GOOGLESHEETS_CREATE_SPREADSHEET(title: "Weekly Budget")` with header row → return edit URL.

### "Update cell B5 to 1200"
Confirm which sheet, then `GOOGLESHEETS_UPDATE_VALUES(range: "Sheet1!B5", values: [["1200"]])`.

## Constraints
- Always confirm spreadsheet name and sheet tab before writing.
- When reading large sheets, limit to first 100 rows and offer to paginate.
- Never clear ranges without explicit confirmation of the exact range.
- Show a preview of the row/values to be written before appending or updating.
