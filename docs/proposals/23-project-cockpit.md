# 23 — Project cockpit: activity, cost, devices, audit log

Status: **shipped** (4a client-only; 4b adds `GET /events` + a `current` flag on
`GET /devices`; read-only git status landed alongside under
[ADR 0011](../decisions/0011-git-surface.md)). Git **commit/push** is
deliberately not here — it changes the security posture and stays gated behind
that ADR.

## Problem

The daemon already knew things the app never showed:

- `projects.last_active` — in the schema, returned by `GET /projects`, and
  silently dropped by `Project.fromJson`.
- `sessions.total_cost_usd` — on the wire (the list route is `SELECT *`) and
  dropped by `Session.fromJson`; spend was visible only inside a live chat header.
- The `events` audit log — rich (every permission decision, session lifecycle
  change, project write, auth reject) and reachable by **no** route at all.
- `GET /devices` / `DELETE /devices/:id` — implemented since M1 and **never
  called by the client**, so `security.md` #4 ("lost phone → kill token") in
  practice meant SSH-ing to the box.

## What shipped

### 4a — surfacing (no daemon change)

- `Project.lastActive` + `relativeAge()` (pure, tested): the dashboard card
  shows `flutter · main · 3d` and the grid sorts most-recently-active first
  (unknown timestamps sink to the end).
- `Session.totalCostUsd` + `costLabel`: session rows and the live-session
  switcher show `$0.042` when there is spend. Empty on Max sessions, where the
  token→dollar figure would be fiction (the same reasoning as the `result` frame
  in claude-ws.md).

### 4b — devices + audit log

- `GET /devices` now marks the caller's own row `current: true`, so the client
  can warn correctly before revoking the phone it is running on.
- `DevicesScreen` (settings → Security): name, paired/seen dates, revoke with
  confirm. Revoking the current device clears the token store and routes back to
  pairing rather than leaving the app authenticated against a dead token.
- **`GET /events?limit&before&kind`** — newest-first, `limit` clamped to 200
  server-side, `before=<ts>` keyset paging, `kind=` prefix filter.
  `idx_events_ts` added via the existing idempotent `migrate()`.
- `AuditLogScreen`: kind filter chips (permission / session / project / auth /
  device), mono `detail`, denials and failures marked.

### 4c (part 1) — read-only git status

`GET /projects/:id/git-status` + a status strip at the top of the project screen:
`main · 3 changed · ahead 1`, tap for the paths. Hidden entirely when the project
isn't a repo. Rationale, guards and the deferred write shape live in
[ADR 0011](../decisions/0011-git-surface.md) / `security.md` #15.

## Security posture

Stated explicitly rather than by omission (`security.md` #14):

- The audit log **is a disclosure surface**: `detail` carries session ids, tool
  names, absolute project paths and file paths. It is bearer-gated behind the
  tailnet — the same trust argument that already justifies `GET /projects`.
- **Read-only.** No DELETE, no PATCH, no POST. An audit log the client can mutate
  isn't an audit log; a test asserts those methods aren't routed.
- **The read is not itself audited.** Logging every read of the log amplifies
  without adding information; a test pins that the row count doesn't move.
- Server-side cap (200) so a client can't ask for the whole history in one gulp.

## Verification

- daemon `npm test` 155 green, incl. 7 in `events.test.ts` (order, prefix filter,
  keyset paging, no self-logging, read-only methods, 401 unauthenticated,
  `current` flag).
- `flutter test` 74 green, incl. 6 in `cockpit_test.dart` (`last_active` parsed
  and tolerant of junk, `relativeAge` shapes, cost formatting incl. the empty
  Max case, device `current`, event row).
- On-device (pending): dashboard shows ages and sorts by them; a native session
  shows spend in the list; settings → Paired devices revokes a second device;
  audit log filters to `permission.*`.

## Touches

- client: `sessions/domain/session.dart` (`lastActive`, `relativeAge`,
  `totalCostUsd`, `costLabel`), `dashboard_screen.dart` (sort + subtitle),
  `project_sessions_screen.dart` + `session_switcher.dart` (cost in the meta
  line), `settings/data/admin_api.dart` (new),
  `settings/presentation/devices_screen.dart` + `audit_log_screen.dart` (new),
  `settings_screen.dart` (Security section)
- daemon: `app.ts` (`GET /events`, `current` on `GET /devices`), `db.ts`
  (`idx_events_ts`)
- tests: `events.test.ts`, `cockpit_test.dart` (new)
- docs: this file, `session-rest.md`, `security.md` #14 (+ #4 status), proposals
  README, docs-map, milestones
