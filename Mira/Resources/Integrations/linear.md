# Linear
composio_toolkit: LINEAR

## When to use
User mentions: Linear, issue, ticket, sprint, project, team, milestone, bug, feature request, priority, assignee, cycle.

## Composio tools (prefix LINEAR_)
- `LINEAR_GET_VIEWER` — current user info
- `LINEAR_LIST_TEAMS` / `LINEAR_GET_TEAM` — team lookup
- `LINEAR_LIST_ISSUES` / `LINEAR_GET_ISSUE` — read issues
- `LINEAR_CREATE_ISSUE` — create issue (confirm first)
- `LINEAR_UPDATE_ISSUE` — update status, assignee, priority (confirm)
- `LINEAR_LIST_PROJECTS` / `LINEAR_GET_PROJECT` — project info
- `LINEAR_LIST_CYCLES` — active sprints/cycles

## Canonical patterns

### "What are my open Linear issues?"
`LINEAR_LIST_ISSUES(filter: {assignee: {isMe: true}, state: {type: {neq: "completed"}}})` → list with title + priority.

### "Create a Linear issue: <title>"
Confirm team + title + description, then `LINEAR_CREATE_ISSUE`.

### "Move issue <ID> to In Progress"
`LINEAR_UPDATE_ISSUE(id, stateId: <in-progress-state-id>)` — resolve state ID with `LINEAR_GET_TEAM` first.

## Constraints
- Always confirm issue details before creating.
- Resolve team/state IDs before writing — do not guess IDs.
