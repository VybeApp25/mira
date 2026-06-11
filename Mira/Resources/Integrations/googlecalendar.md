# Google Calendar
composio_toolkit: GOOGLECALENDAR

## When to use
User mentions: calendar, event, meeting, schedule, appointment, block time, reminder, busy, free, availability, today's schedule, what's on my calendar.

## Composio tools (prefix GOOGLECALENDAR_)
- `GOOGLECALENDAR_LIST_CALENDARS` — list user's calendars
- `GOOGLECALENDAR_GET_CALENDAR_EVENT` / `GOOGLECALENDAR_FIND_EVENT` — look up events
- `GOOGLECALENDAR_LIST_EVENTS` — list events in a time range
- `GOOGLECALENDAR_CREATE_EVENT` — create event (confirm details first)
- `GOOGLECALENDAR_UPDATE_EVENT` — update event (confirm before)
- `GOOGLECALENDAR_DELETE_EVENT` — delete event (confirm before)
- `GOOGLECALENDAR_QUICK_ADD` — natural-language event creation

## Canonical patterns

### "What's on my calendar today?" / "Show my schedule"
`GOOGLECALENDAR_LIST_EVENTS(timeMin: startOfDay, timeMax: endOfDay)` → list chronologically with time + title.

### "Schedule a meeting with <name> at <time>"
Show proposed event summary (title, time, attendees), then `GOOGLECALENDAR_CREATE_EVENT` on approval.

### "Am I free at 3pm tomorrow?"
List events in that hour; report free/busy plainly.

## Constraints
- Always confirm event title, time, and attendees before creating.
- Never delete without explicit confirmation of which event.
