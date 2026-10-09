# ADR 0010 — Session tree read surface (`@file` autocomplete)

**Status:** Accepted (2026-08-07)

## Context

Proposal 22 phase 2b puts `@file` autocomplete in the chat composer: type `@the`,
pick `lib/core/theme.dart`, and the path goes into the turn so Claude can read it.
To offer completions the client needs a list of file names in the project.

Today the daemon has **no directory-listing endpoint**, deliberately.
`GET /sessions/:id/file` (proposal 20, `file-edits.ts`) serves file *content*, but
its capability is the session's own edit set — you can only read back a file this
session already edited — and `security.md` #12 states the intent in as many words:
*"a capability, not a file browser."*

An `@file` autocomplete **is** a file browser. Pretending otherwise would be the
mistake, so this is recorded as a new read surface with its own threat model,
following the ADR 0006 precedent for the write surface.

## Decision

Add `GET /sessions/:id/tree?q=<substr>&limit=<n>` (`project-tree.ts`), returning

```jsonc
{ "root": "/home/user/vibemobile",
  "files": [{ "relPath": "lib/core/theme.dart" }],
  "truncated": false }
```

**Session-scoped, not project-scoped.** The route hangs off a session id, so the
capability is "the project of a session you're already in". A project-wide
`GET /projects/:id/tree` would have been a strictly larger authorization concept
for identical UX — the composer always has a session.

Guards, in order:

1. **Root scope** — the session's project path must pass the shared
   `pathInRoots` (`paths.ts`, ADR 0006). Out of roots → `403`. No session →
   `404`; a session with no project → `404`.
2. **No shell-out** — pure `node:fs` `readdirSync`, matching `scanner.ts`'s
   documented stance. Nothing client-supplied reaches a subprocess.
3. **Symlinks are skipped, never followed.** A symlink inside a root would
   otherwise resolve outside it; skipping is stricter and cheaper than
   realpath-then-recheck per entry.
4. **Excluded dirs** — all dotdirs (so `.git` objects and `.env`-adjacent config
   never appear) plus `node_modules`, `build`, `dist`, `target`, `vendor`,
   `coverage`. These are noise for the user and disclosure for us.
5. **Names only, never content.** This is the containment argument: reading bytes
   still requires the edit-set capability of `GET /sessions/:id/file`. Listing a
   name discloses far less than serving one.
6. **Caps, visibly** — ≤5000 entries walked, ≤50 returned (`limit` clamped
   server-side), and a `truncated` flag the client must surface. No silent
   truncation (house rule, proposal 02 / file-edits.ts).
7. **Audited + rate-limited** — every read logs `session.tree` with
   `<sessionId>:<query>` (query capped at 64 chars); 30/min, same posture as
   `POST /projects`.

**The daemon never resolves a mention.** The client inserts the literal text
`@lib/core/theme.dart` into the turn; Claude reads the file with its own tool,
which still goes through the permission gate. So there is no new *execution*
path — only a new listing.

## Consequences

- A paired device can enumerate file names (not contents) of any project that has
  a session. Bearer-gated behind the tailnet, this is the same trust argument
  that already justifies `GET /projects`; it is now stated explicitly rather than
  by omission. Tracked as `security.md` #13.
- `pathInRoots` gains a third caller and remains the single guard to audit.
- The exclusion list is a maintenance item: a new ecosystem's dep dir (e.g.
  `.pub-cache`-alikes) will show up in completions until added. Dotdirs are
  covered by rule, so the list only grows for non-dot dirs.
- Alternative considered: reuse `git ls-files`. Rejected — it shells out (against
  the scanner's stated design), needs a git repo, and hides untracked files the
  user may well want to mention.
- Alternative considered: project-scoped route. Rejected as a larger capability
  for no UX gain (above).
