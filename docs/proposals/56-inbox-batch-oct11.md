# 56 — Inbox batch: multi-image pick, phone panel fit, update prompt, centred scroll button, resolve_note

**Status:** building 2026-10-11; on-device check pending

Five items from the project's Notes, plus a way to clear the Notes once triaged.

- **Several images at once (mobile).** "Photo library" in the chat composer uses
  `pickMultiImage`; each image is downscaled and uploaded as before and all of them ride on the
  next send. The camera still takes one. No daemon change: a user turn already carries a list of
  image ids.
- **Phone panel buttons no longer wrap.** "New chat" and "Terminal" use a smaller label and
  padding and get the whole row. The agent-CLI menu and Notes moved to icon buttons beside the
  project name, just above them.
- **Update prompt instead of a banner.** When a newer release is found (launch, resume, hourly,
  or Settings → Check for updates) the app asks in a dialog: release notes, then "Update now?"
  with **Later** / **Update now**. Progress and errors (with Retry) show in the dialog; Later
  hides it until the next release or a manual check. The Windows "move the app" case keeps its
  Download button.
- **Scroll-to-bottom button centred.** It sits at the bottom centre of the message list, above the
  composer, instead of the Scaffold's bottom-right FAB slot.
- **Plan usage on the phone bottom bar** (added after v1.0.26). A 48 px strip on top of the
  panel's bottom bar shows the 5h and 7d meters side by side (`PlanUsageMeter(row: true)`, reset
  time on the label line); tapping it opens Usage. Like every dense meter it renders nothing when
  the daemon has no plan data.
- **`resolve_note` (vibe-peers).** Once a note's idea is in the project's docs (a Proposal or
  Milestone), Claude ticks it off with `resolve_note(note_id)`. It marks the note done rather than
  deleting it, so it stays visible (and untickable) in the app's Done section. `list_notes` now
  shows each note's id. Rules: this session's project only (unknown and other-project ids give
  the same error), refused in plan mode, idempotent, audited as `note.resolve`, and it goes through
  the session's own permission gate like any tool. See security.md #21.
