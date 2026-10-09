# Proposal 02 — Diff viewer + swipe approve

Status: **shipped**

## Why
File-edit tool calls (`Edit`/`Write`) are the scariest approvals. Show a git-style
diff in the permission card; swipe right = allow, left = deny.

## What shipped

**Server-side `diffPreview`** — the open question is resolved in favour of the
server, for the reason below. `permission_request` gains one optional field,
present only for `Edit`/`Write`/`MultiEdit`:

```jsonc
"diffPreview": { "relPath": "lib/a.dart", "diff": "@@ -1,1 +1,1 @@\n-one\n+two",
                 "adds": 1, "dels": 1, "truncated": false }
```

Backward compatible: absent for every other tool, and an older client ignores it.
No new frame type, no new route. Spec: [claude-ws.md](../protocols/claude-ws.md#permissions-securitymd--highest-scrutiny).

Diff rendering moved to `diff-preview.ts`, shared by the gate (pre-approval
preview) and `file-edits.ts` (post-hoc file viewer, proposal 20) — one diff
implementation, two callers. The client mirrors it: `DiffLine` was lifted out of
`file_diff_screen.dart` into `diff_lines.dart` and is used by both surfaces.

Card UI: path + `+adds −dels`, diff collapsed to 12 lines with "Show all (N
more)", and a "Diff truncated by the server" note whenever the server cut it.
Swipe right = allow, left = deny.

## Security gate impact — how each invariant is met

- **Render == execution.** `previewForTool(toolName, input, cwd)` is called with
  the *same* `input` object the gate resolves as `updatedInput`; a test asserts
  object identity (`assert.equal(d.updatedInput, input)`), not just deep equality.
  Nothing is reconstructed client-side.
- **No silent truncation.** Reuses `buildEditDiff`'s existing cap, which appends a
  visible `… +N lines truncated` line and sets `truncated: true`; the card also
  states it in words. `adds`/`dels` describe the whole edit, not the shown slice.
- **Swipe has friction.** `dismissThresholds` 0.55 both directions (a pocket flick
  can't cross), a confirm dialog for `Bash`/`Write` and for file tools arriving
  with no preview, `confirmDismiss` always returns false so the controller — not
  the gesture — owns the card's lifetime, and the Allow/Deny buttons stay. Swipe
  is additive, never the only path.
- **Audit unchanged.** Swipe calls the identical `respondPermission(bool)` →
  `{t:'permission'}` frame → `gate.onPermission` → the same
  `permission.allow`/`permission.deny` event rows. There is no swipe-specific
  code path on the daemon at all.

Tracked as an amendment to `security.md` #5.

## Verification

- daemon `npm test` 148 green, incl. 9 in `diff-preview.test.ts`: Edit/Write/
  MultiEdit previews, `null` for `Bash`/`Read`/pathless input, out-of-cwd path
  stays absolute, oversized edit ⇒ `truncated` + marker + honest counts, gate
  attaches the preview and returns the identical input object on allow, no
  preview for non-file tools, replay keeps the preview.
- `flutter test` 68 green, incl. `diffPreview` parse + absent-field cases.
- On-device (pending, **auto-allow OFF**): ask Claude to edit a file, see the real
  diff in the card, swipe to allow, confirm the edit lands and `events` has a
  `permission.allow` row.

## Touches

- daemon: `diff-preview.ts` (new — `buildEditDiff` + `previewForTool`),
  `file-edits.ts` (imports/re-exports it), `permission-gate.ts` (attaches
  `diffPreview`, takes `cwd`), `claude.ts` / `native.ts` (pass `cwd`)
- client: `chat_message.dart` (`DiffPreview`), `chat_session_controller.dart`
  (parse), `diff_lines.dart` (new, shared), `file_diff_screen.dart` (uses it),
  `chat_screen.dart` (`_PermissionCard` → stateful, diff body, `Dismissible`)
- docs: this file, `claude-ws.md`, `security.md` #5, proposals README, milestones
