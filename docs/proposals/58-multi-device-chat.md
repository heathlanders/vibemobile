# 58 — Multi-device chat

**Status:** shipped 2026-10-16 (1.0.31; on-device check passed: phone + Windows)

## Problem

A chat open on two devices (phone + Windows app) only fed the newest client to attach.
`ClaudeSession` and `NativeSession` held one `ws`; `attach` overwrote it. The displaced client
stayed connected (pings fine) but received nothing ("Thinking... - no activity"), and permission
requests went to the other device, so it showed "Approval timed out".

## Design

- **Fan-out.** `ws` becomes a `sockets` set in both engines. `attach` adds, `detach` removes only
  that socket, `send` broadcasts to all (each still gets its own history/pending replay on attach).
  `isReapable` and the "nobody attached" checks (push notify, dialog auto-cancel) mean the set is
  empty.
- **User turns.** The sender adds its own bubble; the daemon sends it `user_ack` and every other
  socket `user_turn {text, messageId, images, ts}` (found in the on-device test: typed text only
  showed on the device that sent it).
- **First answer wins.** `PermissionGate` broadcasts `permission_closed {toolUseID}` on every
  resolution (allow, deny, timeout, auto-allow flush, session end); a second answer returns false.
  Dialogs broadcast the existing `dialog_closed {dialogId}` on response and on timeout. The app
  drops the matching card and cancels its local notification.
- **`stop(code = 1012)` closes every attached socket**, so a client does not keep talking to a
  dead session object. 1012 (idle reap, Mirror takeover): the app retries and resumes via
  getOrStart. 4404 (session deleted, or worktree missing — was 4410, which the app retries, so
  every attached device reconnect-looped): the app stops. A user frame still in flight after
  `stop()` is dropped, not stored.
- **Pushes:** "nobody attached" now means no device at all, so a desktop window left open
  suppresses phone pushes for that chat (someone is watching). Before, that held only when the
  desktop was the newest attach.

## Out of scope

Terminal (`pty-ws.ts`) stays last-attach-wins by design (reattach.md).

## Verification

- Daemon tests: two sockets both receive a turn, detach is per socket, `permission_closed` on both
  and second answer refused, `stop()` closes all with the given code (Claude and native).
- App test: `permission_closed` clears only the matching card.
- On device: open one chat on phone and Windows, approve on one, the other card disappears.
