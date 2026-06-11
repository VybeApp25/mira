# Airtable
composio_toolkit: AIRTABLE

## When to use
User mentions: Airtable, base, table, record, view, Airtable record, add to Airtable, update Airtable, Airtable field.

## Composio tools (prefix AIRTABLE_)
- `AIRTABLE_LIST_RECORDS` — list records in a table (with optional filter formula)
- `AIRTABLE_GET_RECORD` — fetch a single record by ID
- `AIRTABLE_CREATE_RECORDS` — create one or more new records
- `AIRTABLE_UPDATE_RECORDS` — update fields on existing records
- `AIRTABLE_DELETE_RECORDS` — delete records (confirm before)
- `AIRTABLE_LIST_BASES` — list user's accessible bases
- `AIRTABLE_LIST_TABLES` — list tables in a base

## Canonical patterns

### "Show me the open tasks in my project tracker"
1. `AIRTABLE_LIST_BASES` → find correct base.
2. `AIRTABLE_LIST_RECORDS(baseId, tableId, filterByFormula: "{Status}='Open'")` → list name + status + assignee.

### "Add a new client: HealthFlow, contact Jane, deal size $120k"
1. Confirm table name and field mapping.
2. `AIRTABLE_CREATE_RECORDS(baseId, tableId, fields: {Name: "HealthFlow", ...})`.

### "Mark the HealthFlow deal as Closed Won"
1. Locate record with `AIRTABLE_LIST_RECORDS(filterByFormula: "{Name}='HealthFlow'")`.
2. Confirm which record and new value.
3. `AIRTABLE_UPDATE_RECORDS(recordId, fields: {Status: "Closed Won"})`.

### "How many records are in my leads table?"
`AIRTABLE_LIST_RECORDS` with a high `maxRecords` → report count.

## Constraints
- Always confirm base name and table name before creating or modifying records.
- When multiple records match, list options and ask which one to update.
- Never delete records without showing the record name/ID and getting explicit confirmation.
