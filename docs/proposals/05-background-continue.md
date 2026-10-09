# Proposal 05 — Background continue + FCM

## Why
The SDK loop already runs in-daemon ([claude-ws.md](../protocols/claude-ws.md): WS
close = detach, loop lives on). Make it explicit: session keeps working after app
close; FCM on done / needs-input.

## Sketch
Mostly already true — detach ≠ stop. Add: on `result` (turn end) or
`permission_request` while **no client is attached**, fire FCM → deep-link to the
session. Ties into PLAN §4 notification flow.

## Impact
- **Wire:** none. Hooks existing `result` / `permission_request` emission points.
- **Server:** "no attached client" branch → enqueue FCM (needs `devices.fcm_token`).
- **Permission interplay:** `claude-ws.md` says **deny if no client attached**. So
  background = notify-and-wait (re-arm timeout on FCM-tap reattach), NOT auto-run.
  Must not weaken the gate (security.md). Resolve before building.
- **Client:** FCM handler, deep link, background reattach.

## Security gate impact
Highest scrutiny (security.md). This proposal directly pressures the two hard gate
rules in `claude-ws.md`:

1. **Deny if no client attached.** Background = no client attached. Relaxing this
   into "wait when detached" lets a session sit holding a pending privileged command
   with nobody watching — a real change to the security model, not a UI tweak.
2. **120 s deny timeout.** Too short to deliver push → unlock → open → reattach →
   read → decide. A longer hold means the box keeps a queued privileged action
   waiting for minutes — a bigger mistake/attack window.

Safe design (do **not** build without it):
- **Background never auto-runs a permissioned tool.** Read-only / already-allowed
  turns may proceed; a `permission_request` with no client → **emit FCM, then HOLD**
  (extended timeout) instead of the instant 120 s deny.
- **Hold replaces the short deny only if the push was delivered.** FCM fails → fall
  back to strict short deny. Never leave a request pending indefinitely.
- **Still deny if no one reattaches** within the longer window. Human tap stays
  mandatory — we extended the wait, did not remove the gate.
- **Reuse existing replay.** `claude-ws.md` already replays a pending
  `permission_request` on reattach; FCM-tap → reattach rides that for free.
- **Deep link still authenticates.** Notification tap connects via bearer token like
  any other — no shortcut.
- **Audit new states:** `held-pending-fcm`, `fcm-sent`, `timeout-deny-after-hold`.

**Safe iff extended-hold still ends in deny** and a human tap is still what runs the
command. Needs a security.md review row before leaving `idea`.

## Open
- Permission timeout vs FCM round-trip: the 120 s deny is too short for a push. Need
  a longer "awaiting-approval" hold when backgrounded — **security review required**.
