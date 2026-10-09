# CLAUDE.md — VibeMobile

How Claude works in this repo. Behavioral guidelines (derived from Andrej
Karpathy's observations on LLM coding pitfalls, via
multica-ai/andrej-karpathy-skills) merged with project specifics.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks,
use judgment.

---

## Behavioral guidelines

### 1. Think Before Coding
**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First
**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes
**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the request.

### 4. Goal-Driven Execution
**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work")
require constant clarification.

**Working if:** fewer unnecessary diff changes, fewer rewrites from
overcomplication, clarifying questions come before implementation not after.

---

## Project context

VibeMobile = Android app to manage software projects + Claude Code sessions on a
home Linux server. See `PLAN.md` for full architecture.

**Stack:**
- Client: Flutter (Android first), Riverpod, `web_socket_channel`, `dio`,
  `xterm.dart`, `flutter_secure_storage`, FCM.
- Server: Node 20 + TypeScript, Fastify + `@fastify/websocket`,
  `better-sqlite3`, `@anthropic-ai/claude-agent-sdk`, `node-pty`, systemd.
- Transport: Tailscale (`tailscale serve`, ADR 0005), device-pairing token auth.

**Security is not optional** — this app exposes a shell over the network. Any
change touching auth, command execution, or the ingress gets extra scrutiny. The
daemon binds localhost only; `tailscale serve` is the sole ingress. See PLAN.md §5.

**Docs:** every unit of work (spike, decision, protocol, milestone step) gets a
doc in `/docs`. `/docs` is the source of truth; `.claude/docs-map.md` routes you
to the right doc for a given change — read it before touching PTY/WS, Agent SDK,
auth, or the stack.

**When working here:**
- Server (`vibe-daemon/`) and client (`app/`) are separate workspaces; keep
  concerns separate.
- Match the existing Flutter patterns from the user's other projects
  (clean-architecture: data/domain/presentation, Riverpod providers).
- Verify streaming changes against a real PTY/Agent SDK session, not just unit
  tests — the hard bugs are in the wire protocol.

**Where things live** (ADR 0025 — the root SSD filled up once; don't repeat it):
- Repos → `/data/projects`; caches/tools → `/data/cache`; models → `/data/models`;
  Docker data → `/data/docker`; large container data → `/data/volumes/<project>`.
- **Never create a cache or data dir on `/`.** New tool → `/data/cache/<tool>` plus a
  line in `~/.config/data-paths.env` (the one env source of truth).
- pnpm store and repos stay on the same filesystem (hardlinks), so they move together.
- `/mnt/sdd1` is the media library: never modify it. Backups go to `/mnt/sdd1/backups/` only.
- Before moving a repo, check Claude transcript lookup by path (`~/.claude/projects/<encoded cwd>`).
