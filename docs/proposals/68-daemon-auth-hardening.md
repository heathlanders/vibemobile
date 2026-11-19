# 68 — Daemon auth and ingress hardening

**Status:** accepted 2026-11-19 · from the 2026-11-19 project review · daemon only · touches auth: `reviewer` pass required, ADR for the token lifecycle

## Problem

The request gate is sound (one auth hook, hashed 256-bit tokens, argv-only spawns). The token
*lifecycle* is not: a device token is a permanent, unscoped shell credential. Findings below were
read in code on 2026-11-19; line numbers are from that day (v1.0.40) and may have moved.

| # | Finding | Where |
|---|---------|-------|
| A1 | Revoking a device deletes the row but leaves its open WebSockets (chat, PTY) running. WS auth happens once, at upgrade. | `vibe-daemon/src/app.ts:186-194`, `app.ts:86` |
| A2 | Tokens never expire and are never rotated. Devices unseen for months stay valid. | `vibe-daemon/src/auth.ts:66-75` |
| A3 | Any paired device can mint a pairing code and revoke any other device, including the owner's. A stolen token can add a persistent device and lock the owner out. | `app.ts:172`, `app.ts:186` |
| A4 | Rate limits key on `X-Forwarded-For`, trusted when the peer is loopback. That is only safe if every ingress is an HTTP proxy that sets the header. A raw TCP forward lets the client set it and bypass the `/pair` limit on the 8-digit code. | `app.ts:76-80`, `app.ts:104` |
| A5 | `device_name` is unbounded and logged on pairing failure. | `app.ts:110` |
| A6 | `/sessions/:id/file` reads the whole file before capping and skips the secret-name check the browse endpoint has. | `vibe-daemon/src/file-edits.ts:176` |
| A7 | Native read tools check paths lexically only; a symlink inside the project escapes. | `vibe-daemon/src/native-tools.ts:35-38` |
| A8 | The SQLite file is created mode 644; it holds transcripts and FCM tokens. | `vibe-daemon/src/db.ts` |

## Proposal

Work in this order; each step is one small PR with its tests.

1. **A1 — close sockets on revoke.** Keep a `Map<deviceId, Set<WebSocket>>` filled at upgrade and
   cleaned on close. `DELETE /devices/:id` closes them with a 4401 code. The client already treats
   an auth close as "re-pair" (check `app/lib/core/reconnect.dart`).
2. **A4 — global `/pair` cap.** Add a limiter that does not depend on IP: N failed pair attempts
   per window across all clients, then pairing locks until a new code is minted on the box.
   Removing any raw TCP forward is an ops step (private ops note).
3. **A3 — privileged device actions.** Minting a pairing code and revoking *another* device need a
   confirmation that proves box access. Simplest: the route only arms the action; it completes when
   the owner runs a CLI command on the server (same trust root as first pairing). Revoking *self*
   stays one tap. Record the choice in an ADR.
4. **A2 — idle expiry.** A token unused for 60 days is rejected and the row is marked expired (not
   deleted, so the Devices screen can show why). Rotation is out of scope unless the ADR says otherwise.
5. **A5–A8 — small fixes.** Cap `device_name` at 64 chars before use; apply the size cap before the
   read and reuse the secret-name deny list in `file-edits.ts`; `realpath` re-check in
   `native-tools.ts` (copy the pattern in `browse.ts`); `chmod 600` the DB on open.

## Not doing

- Scoped tokens (read-only devices). One owner, no use for it yet.
- Changing the default permission mode. Auto-allow is an owner decision (proposal 18); see
  proposal 69 item R9 for the narrower Bash gate.

## Wire / schema impact

- `devices`: `expired_at TEXT`. WS close code 4401 on revoke/expiry.
- New CLI entry for confirming pair-code mint / remote revoke (name it in the ADR).
- `docs/security.md` rows for A1–A4; `.claude/docs-map.md` unchanged (auth row exists).

## Acceptance

- Test: open a WS as device X, revoke X, socket closes with 4401 and a later frame is not processed.
- Test: 20 wrong `/pair` codes from 20 different forwarded IPs lock pairing.
- Test: device B cannot revoke device A or mint a code without the box-side confirmation.
- Test: a token with `last_seen` 61 days ago gets 401; one at 59 days works.
- Test: symlink in a project pointing outside is refused by the native read tool.
- `cd vibe-daemon && npm test` green; `reviewer` pass recorded in *What shipped*.

## What shipped

- **A1** (2026-11-19). `app.ts` records each authenticated upgrade's device and keeps a
  `Map<deviceId, Set<WebSocket>>` (filled from `websocketServer` `connection`, cleaned on close),
  so `/pty`, `/session` and `/tty` are all covered in one place. `DELETE /devices/:id` removes the
  sockets' `message` listeners, then closes them `4401`. `reviewer` pass found two races, both
  fixed: `/pty` and `/tty` add listeners after `await`s, so a revoke during the await was followed
  by a fresh attach (and a leaked tmux client + heartbeat); the chat route's queued `ready.then`
  frames could still run on a closing socket. All three now bail when the socket is no longer
  `OPEN`. Tests: `pty-ws.test.ts` (4401 + racing frame never reaches the shell, checked by
  removing the listener drop: 3/3 fail; revoke mid-attach never attaches), `session-ws.test.ts`
  (chat socket 4401). `docs/security.md` row 4 updated.
