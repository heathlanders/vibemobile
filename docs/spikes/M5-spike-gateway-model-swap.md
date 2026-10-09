# M5 Spike — Gateway model swap (Agent SDK base-URL mode + tool loop)

**Status:** ⏳ Pending live run (needs a running gateway + provider key)
**Code:** `vibe-daemon/src/spike-gateway.ts`
**Run:**
```
VIBE_GATEWAY_URL=http://127.0.0.1:4000 VIBE_GATEWAY_TOKEN=<tok> \
  npm run spike:gateway -- <cwd> <model-id>
```

## Risk being killed

ADR 0007 routes the Agent SDK through a local Anthropic-compat gateway to reach
any frontier model. The go/no-go unknown: does the SDK's bundled `claude` CLI
actually honor **base-URL mode** (`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`,
passed via `options.env`) instead of its subscription login — **and** keep the
full tool-use loop working when the upstream is a **non-Claude** model reached
through API translation?

If it ignores the base URL, or the translated model can't drive Anthropic-style
tool calls, the whole gateway approach is dead and we fall back to
`claude-code-router` (built for exactly this) or reconsider a native engine.

## What the spike does

Calls `query()` with `options.env = gatewayEnv()` (spreads `process.env`, then
sets `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`) and `options.model = <model-id>`,
against a prompt that **forces a tool call**. Asserts the loop completes:
`init → assistant(tool_use) → user(tool_result) → result success`. The tool
round-trip doubles as the tool-use-fidelity check for translated models.

`permissionMode: "bypassPermissions"` is used **in the spike only** — the real
daemon (`src/claude.ts`) keeps the permission gate.

## Result

_(fill in after the live run)_

```
[event] init  session_id=… model=…
[event] tool_use name=… input=…
[event] tool_result (is_error=false)
[event] result subtype=success cost=$…
[spike] PASS — gateway routing + tool loop work through this model
```

## Findings

_(fill in: did base-URL mode work? tool fidelity per model? any env pitfalls?)_

## Notes

- The `options.env` REPLACES the subprocess env (verified in the SDK `.d.ts`);
  `gatewayEnv()` spreads `process.env` so the CLI keeps `PATH`/`HOME`.
- The gateway must bind `127.0.0.1` only and must **not** be `tailscale serve`'d
  (ADR 0005: the daemon is the sole tailnet ingress).
