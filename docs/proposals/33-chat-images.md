# 33 — Images in chat (tool results, mentioned files, fullscreen viewer)

Status: **building**. Code and tests landed 2026-10-06. The check against a real
Agent SDK session on a device is still pending. New read surface →
[ADR 0021](../decisions/0021-session-image-read-surface.md), `security.md` #23.

## Problem

The chat only showed images the **user** uploaded (proposal 16), as small
untappable thumbnails. Anything image-shaped from the **agent** was lost:
- `claude.ts` `toolResultText()` flattened tool_result content to text, so image
  blocks (Read on a PNG, screenshot MCP tools) were silently dropped.
- Images Claude *creates* (`python plot.py` → `out/chart.png`) had no way to be
  viewed: `GET /sessions/:id/file` is text-only and edit-set-only.

## What shipped

**A. Tool-result images.** In the claude `user` (tool_result) handler, each
`{type:"image", source:{type:"base64"}}` block is decoded and stored through
`storeAttachment()` (`attachments.ts`) — the same magic-byte + size gate as
uploads. Max 4 per result; rejects are dropped and audited
(`attachment.reject`, `<session>:tool_<reason>:<bytes>`). The `tool_result` frame
gains optional `images: [attachmentId]`, also folded into the tool row's
`tool_json` so `history` replays it. Old clients ignore the field.

**B. Rendering.** `chat/presentation/chat_image.dart`:
- `ChatImageStrip` — tappable thumbnails, used for user turns, tool rows, and a
  collapsed `_ToolRunTile` (so an image isn't hidden inside a closed run).
- `ChatImageSource` — `AttachmentImage(id)` or `SessionFileImage(sessionId, path)`.

**C. Fullscreen viewer.** `ImageViewerScreen`: `PageView` over the tapped strip,
`InteractiveViewer` pinch/scroll zoom, black background. Share on mobile
(`share_plus`); "Save to Downloads" on desktop. No new dependency.

**D. Mentioned image files.** `chat/domain/image_paths.dart`
`extractImagePaths()` finds path-like tokens ending in png/jpg/jpeg/gif/webp in a
finished assistant reply (no URLs, deduped, max 6). Each previews via the new
`GET /sessions/:id/image?path=` (ADR 0021). A thumb that fails to load (missing
file, not an image, outside the project) renders nothing.

## Known limits

- A mentioned file shows its **current** content, not the content at the time of
  the reply.
- Paths with spaces aren't detected. SVG isn't supported (not in the sniff
  allowlist, no renderer).
- Out of scope: markdown `![]()` rendering. Images in CLI **user** turns
  (pasted into the terminal) still aren't imported. Only tool-result images are.
- Native engine: no tool images. Its tools (`native-tools.ts`) return plain
  strings (`read_file` UTF-8-decodes the bytes), so a native tool result never
  carries an image block. Adding one would be a new native tool capability, not
  this gap.

## Extension (2026-10-07): CLI mirror + transcript import

CLI transcripts (`~/.claude/projects/…/*.jsonl`) store a Read on a PNG as the
same `tool_result` image block the SDK streams (checked on real transcripts).
`toolResultImages()` moved from `claude.ts` to `attachments.ts` and is now also
called by:
- `external.ts` `Mirror.apply()` (live tail): `tool_result` frame `images` +
  folded `tool_json.images`, same as `claude.ts`.
- `transcript-import.ts` `importTranscriptText()`: the backfill of a discovered
  session and the mirror's attach-time import fold `images` onto the tool row.

Same gate: `storeAttachment()` sniff + 5 MiB cap, ≤4 per result, rejects audited
as `attachment.reject` `<session>:tool_<reason>:<bytes>`. One addition: a blob
byte-identical to one already stored **for the same session** is reused. The
mirror deletes and re-imports the transcript on every attach, so without this
every reattach would duplicate each image.

## Verification

- Daemon: `claude.test.ts` (tool images → attachments + frame + tool_json, junk
  dropped + audited), `session-image.test.ts` (scope, symlink escape, sniff,
  size, audit), `external.test.ts` (mirror live tail + reattach, no duplicate
  blob), `transcript-import.test.ts` (cap 4, junk audited, re-import dedupe).
- Real CLI mirror (2026-10-07): a `claude` CLI in a `vc-*` pane on a private
  tmux socket, mirrored by an in-process daemon on a temp DB, was told from the
  phone side to Read a 32×32 PNG. The live `tool_result` carried one id.
  `GET /attachments/:id` returned `image/png`, byte-identical to the file. The
  model answered "Red." A reattach replayed the same id, with still one
  attachment row.
- Real native session: not possible here. The only local model
  (`ollama:qwen2.5vl:7b`) rejects tools ("does not support tools") and no API
  provider key is set. The native skip rests on the code: tool outputs are strings.
- App: `image_paths_test.dart`, `chat_session_controller_test.dart` (live +
  history + cache round-trip).
- Pending, real session: Read a PNG → thumb under the Read chip, survives
  reattach; generate a chart with Python → thumb under the reply; fullscreen
  zoom/swipe/share on Android + save on Windows.

## Bug fix (2026-10-06): broken thumbnails

First real test showed broken-image tiles. The daemon had stored the images
fine. The cause was the app: the paired base URL ends in `/` (the pairing preset
is `https://box.tailnet.ts.net/`), and `chat_image.dart` joined it to the path
by string concat, which gave `//attachments/<id>`. Fastify 404s that route. Fix:
`_network()` strips trailing slashes before joining. This also fixes thumbnails
of images the user attaches. Dio and the WS URLs were already safe.
