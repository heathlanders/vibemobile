# 29 — Connectivity & runtime diagnostics on the server-health screen

**Status:** shipped 2026-10-06 (see Outcome)

## Problem

The server-health screen (ADR 0019) shows CPU/memory/disks/GPU/service-active, but
the two outages we've actually had were invisible to it: after a server move the app
broke because **Tailscale was logged out** (the `tailscaled` unit was still
"active"), and the daemon ran **Node 18 while the shell had Node 20**. When the app
can't reach the daemon none of this can be seen from the phone anyway — so the
useful half is what the daemon can tell you *before* things break, and what the
operator checks on the PC afterwards.

## Decision (proposed)

Extend `GET /system` (read-only, fixed argv, no client input — same rules as ADR 0019,
security.md #20) with a `diagnostics` block:

- **Tailscale:** `tailscale status --json` → `BackendState` (`Running` / `NeedsLogin`
  / `Stopped`), tailnet DNS name, and whether `tailscale serve status` still maps the
  daemon port. `NeedsLogin` becomes a `system_alert` push (content-free, as today).
- **Runtime:** `process.version`, and the Node the user's login shell would pick
  (`bash -lc 'node -v'`, fixed argv) — flag a major-version mismatch.
- **Daemon:** uptime, SDK version (from `node_modules`), live Claude/terminal session
  counts vs caps, whether FCM is configured.
- Client: a "Diagnostics" section on `SystemScreen` with plain-language fixes
  ("Tailscale is logged out — run `tailscale up` on the server").

## Security / risk

Read-only. `tailscale status` output contains peer names/IPs — return only the
fields above, never the peer list. No restart / re-login / command surface (those
stay out per ADR 0019). A `tailscale` binary that's missing degrades to
`available:false`, like `nvidia-smi`.

## Verification

Unit tests with injected exec fakes for `Running`, `NeedsLogin`, missing binary,
and a Node mismatch; a real-box check of `GET /system` before and after
`tailscale logout` on a throwaway tailnet device.

## Outcome (2026-10-06)

- **Daemon:** `system.ts` `diagnostics()` is cached for 5 min per source and
  parsed by pure helpers (`parseTailscaleStatus`, `servesPort`,
  `parseNodeVersion`).
  - Alerts: `tailscale` (state isn't Running, which FCM still delivers) and
    `tailscale-serve` (Running, but nothing forwards). Logged-out takes
    precedence, because the serve mapping only disappears while logged out and
    comes back by itself (see the server-move runbook).
  - Shell probe: `bash -lc` doesn't load nvm (it lives in `.bashrc`), so the
    probe is `bash -ic`. Under an inherited `npm_config_prefix` nvm refuses to
    switch, so the probe runs under `env -i`.
- **Client:** a Diagnostics section on SystemScreen, with fixes from
  `diagnosticHints`.
- **Real-box check (snf):** Running, serving, `daemon v18.20.8 / shell v20.20.2
  → mismatch` (the known drift), SDK 0.3.291, FCM configured.
- **Not done:**
  - Session counts vs caps (needs the DB in `/system`).
  - The throwaway-tailnet `tailscale logout` check; logging this box out would
    cut the only ingress.
  - The `NeedsLogin` path is covered by fakes only.
