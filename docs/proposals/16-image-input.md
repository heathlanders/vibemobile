# Proposal 16 — Image / screenshot input

> **Status: shipped (2026-06-17).** SDK format de-risked by spike
> (`vibe-daemon/src/spike-image.ts`). Wire/REST contract graduated into
> [claude-ws.md](../protocols/claude-ws.md#attachments-image-input) and
> [session-rest.md](../protocols/session-rest.md#attachments-image-input-claude-sessions).
> This doc is the rationale; the protocols are the source of truth.
> Shipped: server store + multimodal turn, client picker (camera/gallery), and the
> Android OS share-target (`receive_sharing_intent` → `ShareImageScreen` →
> `ChatScreen.initialImageBytes`). Open items below resolved in the build: blobs
> cascade-delete with the session (`db.ts` FK `ON DELETE CASCADE`); `history`
> replays user image turns as `images:[{id, mediaType}]`.

## Why
Coding from a phone, the fastest "look at this" is a screenshot — a failing UI, a
stack trace photo, a design mock. Today a `user` turn is text-only
([claude-ws.md](../protocols/claude-ws.md) client→server `user` frame). Let a user
attach images to a turn so Claude sees them (multimodal input).

## Sketch
- **Capture (client):** `image_picker` — camera, gallery, screenshot (Android
  screenshots land in the gallery). Also register VibeMobile as an Android **share
  target** so `screenshot → Share → VibeMobile → pick session` works.
- **Downscale client-side** before send: Claude caps ~1568px long edge / ~5MB.
  Resize/compress on the phone — fewer bytes over the tailnet, no server work.
- **Transport — REST upload + ref (preferred over inline base64):**
  `POST /sessions/:id/attachments` (multipart) → `{attachmentId, mediaType}`; the
  `user` frame gains `images:[attachmentId]`. Keeps the JSON event channel small;
  a multi-MB blob does not belong in a WS event frame. Mirrors the existing split
  (REST = lifecycle/[session-rest.md](../protocols/session-rest.md), WS = stream).
- **Server (`src/claude.ts`):** build a multimodal SDK user turn — content blocks
  `[{type:'text',text}, {type:'image', source:{type:'base64', media_type, data}}]`
  (exact input shape = open question below). Blob stored on disk, not SQLite.

## Impact
- **Wire:** `user` frame gains optional `images:[attachmentId]`. New REST route
  `POST /sessions/:id/attachments` (multipart) + `GET /attachments/:id` (lazy
  thumbnail fetch). `history` replay must re-emit image refs so reattach redraws
  the bubble.
- **Server:** attachment store (disk, e.g. `~/.vibe/attachments/<id>`), multimodal
  turn builder, `messages` row stores the **ref/path**, not bytes.
- **Client:** picker + share-intent handler, client-side resize, image bubble +
  thumbnail, lazy full-image fetch.

## Security gate impact
Lower risk than the permission gate (image = data, not a command) but it adds a
**file-write path the client controls** — so it gets scrutiny (security.md).
Invariants:

- **Media allowlist + magic-byte check.** png/jpeg/webp/gif only, validated by
  content bytes, not the extension or client-declared `mediaType`.
- **Size cap, enforced server-side.** Reject over the cap before writing.
- **No client-supplied paths.** Random server-minted id as the filename; write only
  to the dedicated attachments dir, **never** a project cwd → no path traversal.
- **Audit.** Log each upload to `events` (size, mediaType, session) like a command.
- **Token-gated.** Upload route behind the same bearer auth as everything else.

## SDK format — RESOLVED (spike, 2026-06-16)
The Agent SDK **accepts image content blocks in the streaming input**. A user turn
with `content` as an array instead of a bare string works:
```
content: [{type:"text", text}, {type:"image", source:{type:"base64", media_type, data}}]
```
Spike `vibe-daemon/src/spike-image.ts` (re-run: `npx tsx src/spike-image.ts`) sent
a solid-red PNG; Claude (`claude-opus-4-8`) replied "Red." Cost $0.14, one turn.

Consequences for the build:
- This is the **same shape** as `ClaudeSession.input()` (`src/claude.ts:114`) — just
  `content` becomes an array. `pushUser` extends to `pushUser(text, images[])`.
- Inline base64 is what the SDK eats → **REST upload stays the wire choice** (small
  WS frames), the server reads the blob off disk and base64s it into the turn. No
  `@file` path ref needed (or offered by the SDK input).

## Open
- Attachment lifecycle: delete blobs when the session is `DELETE`d? Lean yes.
- `history` replay shape for an image turn — `messages.content` stores the ref;
  decide the JSON the `history` frame carries (ref id + mediaType, client fetches).
- Attachment lifecycle: delete blobs when the session is `DELETE`d? Lean yes.
