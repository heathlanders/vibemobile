# Proposal 01 — Voice input → prompt

## Why
Hands-free prompting (driving, couch). Highest-value, lowest-risk: client-only.

## Sketch
Mic button in chat composer → Android `SpeechRecognizer` (on-device) → text into
composer → user edits → sends as normal `user` frame
([claude-ws.md](../protocols/claude-ws.md)). No new wire.

## Impact
- **Wire:** none. Reuses `{t:'user', text}`.
- **Server:** none.
- **Client:** `SpeechRecognizer` plugin, mic permission, composer state.

## Open
- On-device vs cloud STT (privacy → on-device).
- Auto-send vs edit-first (default edit-first; voice is noisy).

## Desktop (2026-10-06)
Mic button now also shown in the desktop (Windows) composer. Same
`speech_to_text` flow, backed by the OS speech recognizer; edit-first. Needs
Windows mic access + online speech recognition enabled; otherwise the
"Speech recognition unavailable" snackbar shows. Server-side transcription
(Whisper) deferred.
