# 31 — Project notes / TODO list

Status: **building**. Code and daemon tests landed 2026-10-06; device check is
still pending. No new security surface: plain DB CRUD behind the existing bearer
gate. Notes are never written into the repo.

## Problem

Ideas and TODOs for a project come up while away from the desk (or mid-session),
and there's nowhere in the app to park them.

## What shipped

**Storage.** A `notes` table in the daemon DB (`db.ts`):
- columns `id`, `project_id` (FK, `ON DELETE CASCADE`), `text`, `done`, `created_at`, `updated_at`
- notes live with the app, not in the project dir, so they never show up in git status
- **scanner prune guard:** `upsertProjects()` (`scanner.ts`) won't prune a project row that has notes. A rescan that stops seeing the dir would otherwise cascade-delete them. This is the same rule as for sessions and project prompts.

**REST** (`notes.ts`, see [session-rest.md](../protocols/session-rest.md)):

| Method | Path | Does |
|--------|------|------|
| `GET` | `/projects/:id/notes` | Open items oldest first, then done items most recently ticked first |
| `POST` | `/projects/:id/notes` | `{text}`: trimmed, 1–4000 chars → `201` |
| `PUT` | `/notes/:id` | Partial `{text?, done?}` (`done` must be a boolean) |
| `DELETE` | `/notes/:id` | `204`, idempotent |

Each mutation writes an audit event: `note.create`, `note.update` or `note.delete`.

**App** (`features/notes/`):
- `NotesPanel` has an add field (Enter adds and keeps focus for rapid capture) and a list of checkbox rows.
  - Tap a row to edit it.
  - Delete by swiping on mobile, or with the trash icon on desktop.
  - Done items are struck through and sink to the bottom.
  - Edits are optimistic and revert with a SnackBar if they fail.
- `showProjectNotes()` opens the panel as a bottom sheet on mobile and as a 480×600 dialog on desktop.
- Entry points:
  - mobile: the notes icon in the `ProjectSessionsScreen` AppBar
  - desktop: the "Notes" button in each project's sidebar row in the workspace

## Not done (on purpose)

- ~~Claude can't see notes.~~ Done (ADR 0028): the `vibe-peers` MCP server has a read-only `list_notes` tool, scoped to the session's project. Notes are the **Inbox** of the work standard (`docs/WORKFLOW.md`).
- No open-count badge on the button, and no sync with a `TODO.md` in the repo.
