# Proposal 08 — Permission card displayName

## Why
The permission card shows the raw `toolName` ("Bash", "Edit"). The protocol already
carries friendlier fields (`title`, `description`, `displayName`) but the UI
under-uses them — a human approving a shell command should see what it actually
does, not just the tool name.

## Sketch
Surface `displayName` (friendly action label) as the card heading and always show
`description` when present. Falls back to `title` → `Allow {toolName}?` when fields
are absent. Pure render change.

## Impact
- **Wire:** none if `displayName` already flows; otherwise add it to
  `permission_request` ([claude-ws.md](../protocols/claude-ws.md)).
- **Schema:** none.
- **Client:** `_PermissionCard` heading/body (chat_screen.dart).

## Open
- Confirm daemon populates `displayName` from the SDK, or derive it server-side per
  tool. **Security:** the card text MUST reflect the exact `input` being
  executed — no friendlier-than-reality labels.
