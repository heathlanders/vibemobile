# Proposal 12 — Session rename / tags

## Why
`title` exists but there's no inline rename and no grouping. As sessions
accumulate, the list gets unscannable.

## Sketch
Inline rename (tap title in chat header or long-press in the session list) →
`PATCH /sessions/:id { title }`. Add a `tags` column for lightweight grouping;
filter the session list by tag.

## Impact
- **Wire:** none.
- **Schema:** `sessions.tags` (CSV or join table); `title` already present.
- **Server:** `PATCH /sessions/:id` for title + tags
  ([session-rest.md](../protocols/session-rest.md)).
- **Client:** editable title; tag chips + filter in the session list.

## Open
- CSV column vs proper tags table — start CSV, migrate if it grows.
- Auto-title from first prompt — **resolved**, see [ADR 0009](../decisions/0009-auto-session-title.md).
