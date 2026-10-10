# ADR 0029 — Pair a new device from an already-paired one

**Status:** Accepted (2026-10-10).

## Context

Pairing (security #3) needed physical or SSH access to the server: someone ran `npm run pair:new`
and typed the printed code into the new device. With the one-line Windows installer and the
`/dl/` download page (proposal 51), that terminal step was the only part of setting up a new
phone or PC that couldn't be done from a device the owner already uses.

## Decision

`POST /devices/pairing-code` mints the **same** code `pair:new` prints: 8 digits, single use,
10-minute TTL, stored only as a hash. It is redeemed through the unchanged public `/pair` route.
The route is:

- **Bearer-gated.** It is not in `PUBLIC`. Only a device that is already paired can mint a code.
- **Audited and traceable.** `pairing_codes.issued_by` stores the issuing device (NULL means the
  server terminal, which now also logs `pair.code`). The `device.paired` event says whose code was
  used (`laptop (code from <device id>)`), so every new device traces back to whoever let it in.
- **Rate-limited** at 5 per minute, like `/pair`.

The app shows it under Settings → Paired devices → **Pair a new device**: the code, a countdown,
and the setup steps (Tailscale, then the installer or APK, then the server address and code).

## Consequences

- Security #3 is no longer "physical server access only". Anyone holding a paired device can
  add another one. That device already has a full shell on the server, so this grants nothing it
  couldn't already do (it could run `pair:new` itself). The bar for a new device stays the same:
  it must be on the tailnet and present a fresh, single-use code.
- A stolen or compromised paired device could add a device of its own. **Revoking a device also
  cancels the unused codes it minted**, so a code can't outlive the revoke. Devices it already
  paired stay paired, so after a loss review Paired devices and revoke anything unknown. The log
  names their issuer, and `device.revoked` now also records who did the revoking.
- Old codes (used or expired) are deleted whenever a new one is minted, which also rules out a
  primary-key collision with an old code's hash.
- The server-side `pair:new` path is unchanged and still the bootstrap for the very first device.
