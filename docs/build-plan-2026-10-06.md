# Master build plan — one Opus session

> **Kickoff for new session:** "Read /home/user/.claude/plans/ok-so-we-need-temporal-dove.md and execute it end to end. Step 0: copy it to /home/user/vibemobile/docs/build-plan-2026-10-06.md (docs are source of truth). Ask me for the exact image-paste error text first."

## Context
ADR 0020 leftovers + desktop QoL + image-paste bug + all open items that need no user decision/hardware. Run as one long session, commit per item, tests green before each commit. `A`=app/lib, `D`=vibe-daemon/src. Read `.claude/docs-map.md` before touching PTY/WS/Agent SDK/auth. Every unit of work gets a doc in /docs.

## Phase A — Bugs / QoL (do first)
1. **Image paste error.** Path: `chat_screen.dart` `_paste()` -> `Pasteboard.image` -> `_uploadBytes` -> `attachment_api.dart` POST `/sessions/:id/attachments` (`D/attachments.ts`). Failure only shows a snackbar `Image upload failed: $e`; no persisted client log, and 413/415 rejections are not audited server-side. Likely causes (confirm, don't assume):
   - Windows `Pasteboard.image` returns BMP/DIB (not in `sniffMediaType` allowlist png/jpeg/webp/gif) -> 415.
   - Full-res screenshot > 5 MB `MAX_BYTES` -> 413. Picker path downscales to 1568px; paste path does not.
   Fix: in `_paste`/`_uploadBytes`, decode + downscale (<=1568 long edge) and re-encode PNG/JPEG on-device before upload (reuse picker's downscale logic ~l.607-620; `package:image` or `dart:ui`). Surface status code in the error. Add daemon audit for rejected uploads (`attachment.reject` with reason/size) so it's debuggable. Add a tiny rolling client log file (`app/lib/core/` logger, path under app support dir) + "Copy logs" in Settings — user asked if app has error log; it doesn't. **First step of build: ask user for the exact snackbar text / reproduce on Windows build.** Tests: daemon 415/413 audit; Dart unit test for downscale/convert.
2. **Selectable chat text.** Wrap chat message list in `SelectionArea` (`chat_screen.dart`; precedent `file_diff_screen.dart:110`). `_Bubble` `onLongPress` -> mobile only; desktop uses `onSecondaryTap` for Copy/Retry/Edit.
3. **Shift+Tab mode cycle.** `_onComposerKey` (l.103): Shift+Tab -> next of `controller.availableModes` in order ask->auto->plan; `_controller.setMode`; return `handled`. No daemon change (chosen: existing 3 modes only).
4. **Sidebar right-click menu.** `workspace_screen.dart` `_ProjectSessions` tile (~l.402): `onSecondaryTapDown` -> `showMenu`: Kill session (confirm), Copy session ID, Rename, Edit tags, Close tab, Open in new split. Reuse `_rename`/`_kill` from `project_sessions_screen.dart` (extract shared fns if coupled). Refresh sidebar `generation`; close tab on kill.

### Progress
- A1 done. Snackbar was `unsupported image type` (415) on Windows desktop; mobile fine. Root cause confirmed in `pasteboard` 0.5.0 Windows plugin: it writes the clipboard bitmap out as a **BMP** file (`CreateBMPFile`) — not in the daemon allowlist. Fix: client `normalizeImage` (dart:ui decode → ≤1568px → PNG, no new image dep), `(HTTP code)` in error, rolling client log `core/app_log.dart` (+ uncaught errors) with Settings → Copy logs, daemon `attachment.reject` audit. Kept the daemon allowlist unchanged (no BMP server-side).
- Added mid-session (user request): auto-titler / Improve-prompt SDK calls persisted transcripts that discovery listed as project sessions. Done — `persistSession: false` + discovery filter + startup purge (ADR 0009 note).
- A2 done: desktop-only `SelectionArea` + right-click bubble menu (ADR 0015 "Desktop input conventions").
- A3 done: Shift+Tab mode cycle (`nextMode`, ADR 0015).
- A4 done: sidebar right-click menu; dialogs extracted to `session_actions.dart` (tested with a fake `SessionApi` — real Dio hangs in the widget-test fake-async zone). Server crashed mid-A4; resumed in a new session.
- B5 done: `rate_limit_event` → `ingestRateLimit` (shape captured from a real haiku call; ADR 0020).
- B6 done: `usage_reset` push (`startUsageNudger`; 5 h: <30 min & <50 %, weekly: <12 h & <50 %; once per reset). B7 docs done (ADR 0020, security #22, milestones, PLAN).
- C9 done (user chose shared connection): `ChatControllerPool` (`chatControllerPoolProvider`, ref-counted per session id) used by `ChatScreen` + `MultiChatScreen`; daemon `detach(ws)` no-op for a superseded socket (regression test). Proposal 19, claude-ws.md, milestones updated. Cross-device fan-out not done (multi-device sync).
- C8 done: `ChatScreen.onTitle` (fires on each new `title` frame + a pooled controller's held title) → workspace `_titles` map drives tab labels. Widget test. Gap noted in proposal 24: manual REST rename sends no `title` frame, so open views keep the old name.
- C10 done: `DashboardScreen._navActions` — <360 dp keeps the first 2 icons (Search, Prompt library) + `More` popup; ≥360 dp unchanged, order unchanged. Widget test at 340/411 dp.
- C11 done: `GET /spend/session/:id` + chat menu "Token usage" sheet (`session_spend_sheet.dart`); project spend rows carry `claudeMdBytes` (stat, no path leaked) → `savingsTips(byProject:)` CLAUDE.md >40 KB tip. Daemon + widget tests; session-rest.md, ADR 0017, milestones.
- C12 done: Share transcript… (`share_plus` ^13, text only) + search jump-to (`ChatMessage.ts` from history, `findHitIndex`, estimate-then-`ensureVisible`, tint). Proposals 06/10 + README. Needs Windows build check (new plugin).
- Fix: pooled controller dropped a later view's `initialMessage` (prompt sent into a session open in a tab) → `sendWhenLive`. Regression from C9.
- C13a done: proposal 04 session templates — `template` tag, project "Start from template" → `PromptUseScreen(initialTarget: new:<project>)`; server unchanged (proposal 15 `initialPrompt`).
- C13b done: proposal 29 diagnostics in `GET /system` (tailscale state/serve, node daemon vs fresh-shell via `env -i bash -ic`, SDK version, FCM) + `tailscale`/`tailscale-serve` alerts + SystemScreen Diagnostics section with fix hints. Real box: node drift v18/v20 flagged. security.md #20, session-rest.md.
- C14 done (user approved the write surface): `exportMirrorImages` → 0700 dir, 0600 `<id>.<ext>`, 24 h sweep; each path is its own bracketed paste → `[Image #N]` (real CLI check). security.md #8/#16, ADR 0012. Was: needs user decision: a running CLI only takes images as file paths, but attachments are SQLite BLOBs by design ("no filesystem write surface", security.md #8). Doing it = writing image files to disk (new write surface).
- C15 done (user chose the suggested design): Settings "Model per task" (`TaskModelPrefs`), `suggestTask` keyword heuristic, prompt-use screen preselects + Change. ADR 0016. Was: needs user decision: per-task model profiles / auto-suggest is open product design (which tasks, where stored, what drives the suggestion).
- C16 done: native resume replays tool rows as one-line `[tool …]` notes folded into assistant turns (`replayHistory`, strict alternation). Fake-SDK tests; no live provider run (keys out of scope). ADR 0008.
- D17 done (user decisions): terminal input audited as start/end + byte count + duration, never content (`input-audit.ts`, PTY + mirror tty); failed-auth limiter 20/10 min per client IP with `trustProxy: "127.0.0.1"` (XFF from loopback only) → 429 + one `auth.ratelimit` event. security.md #5 → Done.
- D18 done (user decision): Auto mode asks for Claude file tools outside cwd/registered projects/~/.claude (`file-scope.ts`, symlink-safe, `permission.out_of_scope`). Spike D18 proved out-of-cwd Read reaches canUseTool. security.md #7 → Done.
- E19 done: milestones M0/M1/M5/M6 rows + xterm/ingress/FCM-blocked/Phase 5 lines; PLAN §5 checklist ↔ security.md, §7 Node note (real state: daemon v18, shell v20); Cloudflare leftovers (M0 spike 2 follow-ups, systemd unit comment); proposal 25 status; ADR 0006 client follow-up shipped; README spike/protocol index. Also repaired security.md #8 row (notes cell lost by an earlier edit).

## Phase B — ADR 0020 deferred
5. Ingest SDK `rate_limit_event` in `D/claude.ts` (near usage frame ~l.526) into `D/usage.ts` cache (inspect real event shape first; honor gateway null + TTL).
6. Push when window near reset with spare capacity: `D/push.ts`; thresholds as constants (e.g. <30 min left, <50% used), dedupe per `resetsAt`, no secrets in payload.
7. Docs: ADR 0020 "Next"->done, `docs/security.md` row for `/usage/plan`, `docs/milestones.md` entry, PLAN.md mention.

## Phase C — Client UX bugs (no decisions needed)
8. Workspace tab labels follow auto-title renames (milestones.md:364).
9. Same session open in Multi-chat + tab fights over socket (:364) — single-owner or shared controller.
10. Phone dashboard app bar overflow menu (<360dp) (:366).
11. Per-session token detail in chat header + CLAUDE.md-size savings tip (ADR 0017:54).
12. Share-sheet export (proposal 06); jump-to-message in search (proposal 10).
13. Proposal 04 session templates; proposal 29 connectivity/runtime diagnostics.
14. Image attachments into mirrored CLI session (ADR 0012:85).
15. Per-task model profiles + auto-suggest model (ADR 0016:77).
16. Native resume summarize/replay-tools (ADR 0008:48).

## Phase D — Security hardening (docs/security.md)
17. #5 rate-limit beyond `/pair`; per-keystroke terminal audit. 18. #7 scope command execution to project dirs. Security-sensitive: extra scrutiny, tests required.

## Phase E — Docs hygiene
19. Fix stale milestones table (M0/M1/M5 rows, Phase 5 FCM, :182 blocked text), PLAN.md §5 checklist vs security.md, §7 Node 18/20 note, obsolete Cloudflare follow-up, proposal 25 status, ADR 0006 follow-up note.

## Explicitly NOT in session (need user decision / hardware / keys)
Git commit/push (+worktree, checkpoint/rewind), native Tier 3 write/bash, system actions (restart/clean), relaxing 120s permission hold, iOS, gateway rollout, provider-key live spikes, Tailnet ACL, box swap/disk cleanup, desktop tray push, FCM background continue, on-device verification passes, multi-device state sync. (Operator note: box swap 100% / disk 92% — ops task.)

## Verification
- Daemon: `cd vibe-daemon && npm test`; app: `cd app && flutter analyze && flutter test`.
- Real-session checks per CLAUDE.md (wire protocol): rate_limit_event reaches cache; mode echo frame after Shift+Tab; attachment upload with real clipboard PNG/BMP.
- Windows desktop items (paste, select/copy, right-click, Shift+Tab) need user to build on PC (robocopy /MIR deploy per memory) — session should list a manual checklist at end.
- Order: A -> B -> C -> D -> E; commit per item with Co-Authored-By trailer.
