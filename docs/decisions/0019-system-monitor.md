# ADR 0019 — Read-only system monitor and low-resource alerts

**Status:** Accepted (2026-10-05). Roadmap phase 5 of [ADR 0015](0015-desktop-client.md).

## Context

The box has frozen before. A Flutter release build hit OOM (see the
server-OOM memory notes), and on first run of this monitor `/` was 92% full
with swap 100% used. There was no way to see machine health from the app.

## Decision

1. **`system.ts`** builds a **read-only** snapshot. The table shows what it
   reports and where each figure comes from:

   | Figure | Source |
   |---|---|
   | CPU % | Two `/proc/stat` samples taken 250 ms apart |
   | Load, memory, swap, uptime | `/proc` |
   | CPU temperature | `/sys/class/hwmon`: the `coretemp`/`k10temp`/`zenpower`/`cpu_thermal` chip's package (`Package id N`, `Tctl`, `Tdie`) sensor, else its first; added 2026-10-06 |
   | Network | `/proc/net/dev` byte counters, virtual interfaces dropped; the client computes rates between polls; added 2026-10-06 |
   | Disks | `statfs`, de-duplicated per filesystem; paths from `VIBE_DISKS`, default `/,/home` |
   | GPU | `nvidia-smi`, if installed |
   | Top 8 processes by RSS | `ps` |
   | Service states | `systemctl is-active` for `VIBE_SYSTEM_UNITS` (default `tailscaled,earlyoom`) and `VIBE_USER_UNITS` (default `vibe-daemon`) |

   - Commands are fixed argv arrays run with `execFile`, never a shell. Unit
     names are validated (no leading `-`) and passed after `--`.
   - **`GET /system`** returns the snapshot. The client polls it every 3 seconds
     while the page is open. That's simpler than a WebSocket stream and enough
     at this refresh rate.
2. **Alerts**, with fixed thresholds:
   - memory: less than 10% available
   - swap: more than 50% used
   - any disk: more than 90% full
   - GPU: 85 °C or hotter
3. **Monitor:** checks every 60 seconds and sends one content-free
   `system_alert` push (ADR 0013) when an alert starts.
   - Each alert has a 6-hour cooldown, re-armed once it clears.
   - Each push is also written to the audit log as `system.alert` with the
     messages.
   - The phone shows "Server needs attention". The System page (desktop rail,
     phone Settings → Server health) shows which resource and why.
4. **No actions in v1:** no kill, restart or cleanup. Any write action would
   need its own ADR, an allowlist and an audit trail (shell-over-network rule,
   PLAN §5).

## Consequences

- **Security:** read-only, bearer-gated, no new ingress. It does expose process
  names and service states to paired devices, which already have a shell.
- The desktop gets no push, because it has no FCM. It sees alerts as banners on
  the System page.
