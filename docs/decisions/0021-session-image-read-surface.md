# ADR 0021 — Session image read surface (chat image preview)

**Status:** Accepted (2026-10-06)

## Context

Proposal 33 shows images Claude writes or mentions (e.g. "saved to
`out/chart.png`") inline in the chat. That needs file **bytes** from the
project. The existing reads don't fit:
- `GET /sessions/:id/file` (proposal 20) is capability-scoped to the session's
  edit set and is text-only (NUL sniff ⇒ `415`). Images are usually produced by a
  Bash command, so they are never in the edit set.
- `GET /sessions/:id/tree` (ADR 0010) is names only. Its argument rested partly on
  "reading bytes still needs the edit-set capability".

So this is a new read surface. Like ADR 0010, it is recorded as one rather than
smuggled into an existing route.

## Decision

Add `GET /sessions/:id/image?path=<relative-or-absolute>` (`session-image.ts`).
It returns the raw image bytes with the sniffed `Content-Type`.

Guards, in order:

1. **Session-scoped.** Unknown session or a session without a project ⇒ `404`.
   Missing `path` ⇒ `400`.
2. **This project only.** A relative `path` resolves against the session's project
   root. Both root and target are `realpath`'d (symlinks resolved), and the target
   must be strictly inside the session's **own** project root, not just any
   configured root (a sibling project ⇒ `403`). `pathInRoots` is re-checked as
   defence in depth.
3. **Regular file, size-capped before reading.** `stat` ⇒ not a file ⇒ `404`;
   over `VIBE_MAX_ATTACH_BYTES` (5 MiB) ⇒ `413`. The read is bounded to the cap
   even if the file grew after `stat`.
4. **Image bytes only.** The bytes must sniff as png/jpeg/webp/gif
   (`sniffMediaType`, the upload allowlist), else `415`. The extension is
   irrelevant: `.env` renamed to `x.png` is refused. This is the containment
   argument. The route cannot return text, keys or source, only data that is
   already a valid raster image.
5. **Audited + rate-limited.** Each served read logs `file.image`
   `<session>:<relpath>:<bytes>`; 120/min (a chat history may hold many
   previews). `Cache-Control: no-store`.

The client never sends a path it didn't get from the conversation. Even so, the
daemon treats `path` as hostile, and the guards above are the whole defence.

## Consequences

- A paired device can read any **image file** inside a session's project. That is
  strictly less than the shell the same device already has (PTY,
  `security.md` #1–3), and behind the same bearer + tailnet trust. Tracked as
  `security.md` #23.
- ADR 0010's "names only, content needs the edit set" now has one exception:
  image bytes. Non-image content still needs the edit-set capability.
- `sniffMediaType` is now the guard for both writes (uploads, tool-result images)
  and this read. Widening its allowlist (e.g. SVG, which can carry script) widens
  this read too, so any change to it needs its own review.
- Alternative considered: add images to the edit-set capability of
  `/sessions/:id/file`. Rejected. Generated images come from Bash, not
  Edit/Write, so they would never be in the set.
- Alternative considered: have Claude Read the image so it arrives as a tool
  result (part A). Rejected as the only path. It costs tokens and a turn for
  something the user just wants to look at.
