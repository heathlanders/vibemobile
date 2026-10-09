# 19 — Multi-chat grid (up to 6 live sessions at once)

Status: **shipped**

## Problem

Each Claude session opens fullscreen; reviewing several parallel agent runs
means bouncing through the navigator. Managing N concurrent sessions from the
phone needs all of them visible at once.

## UX

A `MultiChatScreen` (dashboard app-bar → grid icon) shows up to **6** live
Claude sessions as streaming tiles:

- **Tile** (`SessionTile`): read-only transcript tail (last 8 rows, plain text,
  no bubbles/images), title, connection-state dot (§2 tokens; live = no dot),
  busy spinner, `lock` badge when a permission/dialog is pending, remove button.
- **Tap a tile** → pushes the full `ChatScreen` (composer, images, voice,
  permissions, search) — full chat features, one keyboard at a time.
- **Add** via app-bar `+`: picker of live claude sessions not already on the
  grid (same source as the session switcher). Creating brand-new sessions stays
  in the project flow (future extension: create-from-grid).
- **Remove** = detach only; deleting a session remains the expanded
  ChatScreen's close action. A session deleted from the expanded view is pruned
  from the grid on pop.
- Grid membership persists across app restarts (`MultiChatPrefs`,
  SharedPreferences); dead/deleted ids are pruned on load.

Auto layout, fills the viewport exactly (`gridDims`, pure/unit-tested):

| n | portrait | landscape |
|---|----------|-----------|
| 1 | 1×1 | 1×1 |
| 2 | 1 col × 2 rows | 2 cols × 1 row |
| 3–4 | 2×2 | 2×2 |
| 5–6 | 2 cols × 3 rows | 3 cols × 2 rows |

## Wire / architecture impact

**None on the wire.** The grid opens one `WS /session/:id` per tile — the
existing per-session channel ([claude-ws.md](../protocols/claude-ws.md)); no
multiplexing frames added.

The decisive daemon constraint: each `EngineSession` holds **one** client
socket (`attach(ws)` → latest socket wins; the old one is silently orphaned).
Therefore:

- The tile and the expanded view **share one `ChatSessionController`** (one
  socket). Since 2026-10-06 every view takes it from the app-wide
  `chatControllerPoolProvider` (`chat/presentation/chat_controller_pool.dart`),
  keyed by session id and ref-counted (`ChatScreen`'s `controller` param is
  now a test hook only).
- Expanding/collapsing a tile causes **no re-attach** — the grid State stays
  mounted under the pushed route, so the socket never drops.
- ~~Known limitation: the same session in the grid AND a standalone
  ChatScreen / workspace tab orphaned one socket.~~ Fixed 2026-10-06: the pool
  hands both views the same controller, so one device opens one socket per
  session. The daemon's `detach(ws)` also ignores a superseded socket closing
  (it used to null the live one). Two *devices* on one session still fight —
  latest attach wins ([reattach.md](../protocols/reattach.md)); fan-out is
  multi-device sync, not done.

Controller lifecycle: the pool creates + starts a controller on the first
`acquire` and disposes it on the last `release`. Each holder registers its own
re-auth handler; on 4401 the newest still-held one runs. A view that brings a
first turn (`initialMessage`, e.g. a prompt sent into a session that's already
open in a tab) to an already-pooled controller hands it over via
`sendWhenLive`; the controller sends it now if live, otherwise once connected. Leaving the grid
releases its holds — a socket closes only if no tab still shows that session;
re-entry re-attaches and the daemon replays `history`.

## Cap bump

`VIBE_MAX_CLAUDE` default raised **4 → 6** so grid capacity matches the server
([session-rest.md](../protocols/session-rest.md#concurrency-caps)). Still
env-tunable per host.

## Touches

- client: `features/multichat/*` (new), `chat_screen.dart` (controller
  injection), `dashboard_screen.dart` (entry)
- daemon: `sessions.ts` (cap default)
- docs: `session-rest.md` (cap), this file
