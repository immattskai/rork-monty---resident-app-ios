# Board tabs (Resident App)

Implement four Board tabs in Swift backed by the shared Supabase backend.

## Access gate
- [x] Use `app.isBoardMember` from existing `fetchIsBoardMember` check.
- [x] Snapshot remains visible to all residents (read-only).
- [x] Meetings/Tasks/Financials render "Access Restricted" empty state for non-board residents.

## Snapshot
- [x] Parallel queries: property_units, tickets (last 30d + previous 30d), board_tasks.
- [x] KPI cards: Occupancy, Open Tickets (delta), Avg Resolution (delta), Open Board Tasks.
- [x] Mini charts: weekly ticket volume + tickets by priority (Swift Charts).

## Meetings
- [x] Refactored list with Upcoming/Past split + hero card for next meeting + RSVP pill.
- [x] Detail screen with 4 sub-tabs: Agenda, Notes, Votes, Minutes.
- [x] RSVP upsert into `board_meeting_attendees`.
- [x] Uses `board_agenda_items!board_agenda_items_meeting_id_fkey` FK hint.

## Tasks
- [x] Horizontal Kanban (backlog → todo → in_progress → done).
- [x] Long-press action sheet: change status / priority / delete.
- [x] Tap card → detail sheet (description + comments).
- [x] FAB → create task.

## Financials
- [x] AR aging per unit, PII stripped (no resident names).
- [x] Bucket totals (Current / 1-30 / 31-60 / 61-90 / 90+) + KPI chips.
- [x] Per-unit list sorted lien-eligible → 90+ desc → total desc.
- [x] $2,500 lien threshold (`ArAging.lienThresholdCents`).
