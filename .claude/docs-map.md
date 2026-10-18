# Docs map (Claude-facing)

Derived from `/docs`. Tells Claude **which doc to read for which work**, so
`/docs` stays the source of truth and `CLAUDE.md` stays lean.

> Maintenance: when you add/relocate a doc under `/docs`, add a row here.
> `/docs/README.md` is the human index; this file is the routing table.

## Read before you…

| When you're about to…                                  | Read first                                      |
|--------------------------------------------------------|-------------------------------------------------|
| Touch the terminal tab / PTY / WS bytes                | `docs/protocols/pty-ws.md`, `docs/decisions/0003-pty-ws-wire-protocol.md`, `docs/decisions/0004-tmux-backed-pty.md` |
| Touch the terminal's on-screen keys (Esc/Tab/Ctrl/arrows) | `docs/proposals/38-terminal-key-row.md` (surface: `terminal/presentation/terminal_key_row.dart`, `terminal/domain/ctrl_latch.dart`, `terminal_session_controller.dart`) |
| Touch terminal reconnect / drop-detect / reattach      | `docs/protocols/reattach.md` |
| Create / delete / list sessions (REST lifecycle)       | `docs/protocols/session-rest.md` |
| Create a new project / scaffold library (`POST /projects`, `/scaffolds`) | `docs/proposals/17-new-project-scaffold.md`, `docs/decisions/0006-project-create-write-surface.md`, `docs/security.md` #9 |
| Touch Claude sessions / Agent SDK / chat events        | `docs/protocols/claude-ws.md`, `docs/spikes/M0-spike1-agent-sdk-auth.md` |
| Touch session modes (Ask/Auto/Plan), `ExitPlanMode`, `setPermissionMode`, the mode chip / `exit_plan` card | `docs/proposals/25-permission-modes.md`, `docs/protocols/claude-ws.md` (Modes), `docs/spikes/M7-spike-plan-mode.md`, `docs/security.md` #5 (surface: `claude.ts` `setMode`/`exitPlan`, `engine.ts`, `chat/presentation/mode_widgets.dart`) |
| Touch the multi-chat grid / session tiles              | `docs/proposals/19-multi-chat-grid.md`, `docs/protocols/claude-ws.md` |
| Touch session file diffs / the file-read endpoint      | `docs/proposals/20-session-file-viewer.md`, `docs/protocols/session-rest.md`, `docs/security.md` #12 |
| Touch diff rendering / the permission card / swipe approve | `docs/proposals/02-diff-viewer.md`, `docs/protocols/claude-ws.md` (Diff preview), `docs/security.md` #5 (surface: `diff-preview.ts`, `permission-gate.ts`, `diff_lines.dart`) |
| Add a model / touch the model picker / gateway routing | `docs/decisions/0007-model-agnostic-gateway.md`, `docs/spikes/M5-spike-gateway-model-swap.md`, `docs/security.md` #10 |
| Add a provider / touch model discovery, `provider:model` ids, the models file, agent CLI presets, hand-off | `docs/decisions/0016-model-registry-and-agent-presets.md`, `docs/protocols/session-rest.md` (GET /models, GET /presets), `docs/security.md` #11 + #19 (surface: `providers.ts`, `presets.ts`, `gateway.ts`, `tmux.ts` `createSession`, `chat/domain/handoff.dart`, `sessions/presentation/model_picker.dart`) |
| Touch the native (non-Claude) engine / add a native provider / native tools | `docs/decisions/0008-native-engine.md`, `docs/spikes/M6-spike-native-engine.md`, `docs/security.md` #11 (engine surface: `native.ts`, `native-tools.ts`, `permission-gate.ts`, `engine.ts`) |
| Touch session titles / the auto-titler                  | `docs/decisions/0009-auto-session-title.md`, `docs/protocols/claude-ws.md`, `docs/protocols/session-rest.md` (surface: `titler.ts`, `claude.ts`, `native.ts`) |
| Add animation / loading / empty states on any screen    | `app/DESIGN.md` §9 (motion tokens + patterns), `docs/proposals/21-motion-polish.md` (surface: `core/widgets.dart`, `core/spacing.dart`) |
| Touch the composer / add a slash command / `@` mention  | `docs/proposals/22-composer-commands.md` (surface: `chat/domain/composer_triggers.dart`, `chat/presentation/composer_overlay.dart`) |
| Touch chat images (tool-result images, `GET /sessions/:id/image`, the image viewer) | `docs/proposals/33-chat-images.md`, `docs/decisions/0021-session-image-read-surface.md`, `docs/security.md` #8 + #23 (surface: `attachments.ts` `storeAttachment`/`sniffMediaType`, `attachments.ts` `toolResultImages` (used by `claude.ts`, `external.ts`, `transcript-import.ts`), `session-image.ts`, `chat/presentation/chat_image.dart`, `chat/domain/image_paths.dart`) |
| Touch chat link rendering (tappable URLs in messages) | `docs/proposals/34-chat-links.md` (surface: `chat/domain/link_spans.dart`, `chat/presentation/linkified_text.dart`) |
| Touch assistant message rendering (markdown, code blocks, tables) | `docs/proposals/35-chat-markdown.md` (surface: `chat/domain/markdown.dart`, `chat/presentation/markdown_text.dart`, `chat_screen.dart` `_align`/`_text`) |
| Touch thinking / reasoning display (`thinking` frames, `ThinkingTile`, `VIBE_SHOW_THINKING`) | `docs/proposals/36-thinking-blocks.md`, `docs/spikes/M9-spike-thinking.md` (surface: `claude.ts` `handle`/`start`, `chat_session_controller.dart`, `chat_screen.dart` `ThinkingTile`) |
| Touch the live model switch (`set_model` / `model` frames, "Switch model…") or Hand off | `docs/proposals/37-live-model-switch.md`, `docs/decisions/0016-model-registry-and-agent-presets.md` (surface: `claude.ts` `setModel`/`modelFrame`, `session-ws.ts`, `chat_screen.dart` `_switchModel`/`_handoff`) |
| Touch reasoning effort (`set_effort` / `effort` frames, `EffortSheet`) | `docs/proposals/39-effort-control.md`, `docs/spikes/M11-spike-effort.md` (surface: `claude.ts` `setEffort`/`effortFrame`, `session-ws.ts`, `chat/presentation/effort_sheet.dart`) |
| Touch the context meter / compaction (`context`, `compacted`, `compact`, `notice` rows, `ContextStrip`) | `docs/proposals/40-context-meter-compact.md`, `docs/spikes/M12-spike-context-compact.md` (surface: `context.ts`, `claude.ts` `emitContext`/`compact`/`handle` compact_boundary, `chat/presentation/context_sheet.dart`) |
| Touch skills / slash commands in the composer (`commands` frame, `/` suggestions) | `docs/proposals/41-slash-commands.md`, `docs/spikes/M13-spike-slash-commands.md`, `docs/proposals/22-composer-commands.md` (surface: `commands.ts`, `claude.ts` `loadCommands`, `chat/domain/slash_command.dart`, `chat_screen.dart` `_suggestions`) |
| Touch branching a conversation (`POST /sessions/:id/fork`, "Branch from here") | `docs/proposals/42-branch-conversation.md`, `docs/spikes/M14-spike-fork.md`, `docs/decisions/0023-checkpoint-rewind.md` (the `sdk_uuid` it relies on) (surface: `fork.ts`, `chat/presentation/branch_sheet.dart`, `chat_screen.dart` `_branch`) |
| Touch MCP servers / "Tools & integrations" (`get_mcp`, `mcp_action`, `mcp` frame) or anything about hooks | `docs/proposals/43-mcp-view.md`, `docs/spikes/M15-spike-mcp.md`, `docs/security.md` #28 (surface: `mcp.ts`, `claude.ts` `sendMcpStatus`/`mcpAction`, `chat/presentation/mcp_sheet.dart`) |
| Plan, propose, record or hand over work; write a handoff / proposal / milestone; use Notes; avoid auto-compaction | `docs/WORKFLOW.md`, `docs/decisions/0028-work-management-standard.md` (surface: `vibe-daemon/src/peer-tools.ts` `listNotes`/`resolveNote`, `scaffold-seed.ts`, `retrofit-workflow.ts`, `app/.../chat/domain/rollover.dart`, `context_sheet.dart`) |
| Touch scheduled prompts / the scheduler / unattended runs | `docs/decisions/0027-scheduled-prompts.md`, `docs/protocols/session-rest.md` (Scheduled prompts), `docs/security.md` #29 (surface: `schedule.ts`, `server.ts` `startScheduler`, `app/lib/features/schedules/`) |
| Touch PR / CI status (`GET /sessions/:id/ci`, "Pull request & CI…") | `docs/proposals/45-pr-ci-status.md`, `docs/decisions/0024-git-write-surface.md` (why push/PR creation is not built), `docs/security.md` #30 (surface: `ci.ts`, `chat/presentation/ci_sheet.dart`) |
| Touch the file browser (`GET /sessions/:id/browse[/file]`, "Browse files…") or any new project-file read | `docs/proposals/46-file-browser.md`, `docs/decisions/0010-session-tree-read-surface.md`, `docs/proposals/20-session-file-viewer.md`, `docs/security.md` #31 (surface: `browse.ts`, `chat/presentation/file_browser_screen.dart`) |
| Touch daemon settings (`GET/PUT /settings`), the session rules appended to prompts, the disk alert threshold or the free-space guard | `docs/decisions/0026-session-rules-and-settings.md`, `docs/decisions/0025-storage-layout.md`, `docs/spikes/M10-spike-session-rules.md`, `docs/security.md` #27 (surface: `settings.ts`, `claude.ts` `start`, `native.ts`, `system.ts`, `sessions.ts`/`projects.ts` guards, `app/lib/features/settings/`) |
| Touch the file-name listing / `@file` tree route        | `docs/decisions/0010-session-tree-read-surface.md`, `docs/protocols/session-rest.md`, `docs/security.md` #13 (surface: `project-tree.ts`, `paths.ts`) |
| Touch the audit log / device management / dashboard metadata | `docs/proposals/23-project-cockpit.md`, `docs/protocols/session-rest.md`, `docs/security.md` #4 + #14 (surface: `app.ts` `/events`, `settings/data/admin_api.dart`) |
| Touch git status / add any git write (commit, push)     | `docs/decisions/0011-git-surface.md`, `docs/decisions/0024-git-write-surface.md`, `docs/security.md` #15 (surface: `git.ts` — `scanner.ts` stays no-shell-out) |
| Touch file rewind / checkpointing (`POST /sessions/:id/rewind`) | `docs/decisions/0023-checkpoint-rewind.md`, `docs/proposals/27-checkpoint-rewind.md`, `docs/spikes/M8-spike-checkpoint-rewind.md` |
| Touch worktree sessions (`worktree:true`, `.vibe-worktrees`) | `docs/decisions/0022-worktree-sessions.md`, `docs/proposals/28-worktree-per-session.md`, `docs/decisions/0024-git-write-surface.md` |
| Create a project, add a cache/tool, move a repo, touch Docker data, or change `VIBE_PROJECT_ROOTS` / `VIBE_DISKS` | `docs/decisions/0025-storage-layout.md` (env source of truth: `~/.config/data-paths.env`; never create caches on `/`) |
| Touch CLI-session mirroring / `vc` / the `/tty` route   | `docs/decisions/0012-external-session-mirror.md`, `docs/protocols/claude-ws.md` (Lifecycle), `docs/security.md` #16 (surface: `external.ts`, `session-ws.ts`) |
| Touch push notifications / FCM / notification actions  | `docs/decisions/0013-push-notifications.md`, `docs/protocols/claude-ws.md` (gate rules), `docs/security.md` #17 (surface: `push.ts`, `sessions.ts` pending/answer routes, `app/lib/features/notifications/`) |
| Touch the CLI push hook / `hook.sock`                   | `docs/decisions/0014-cli-session-push-hook.md`, `docs/decisions/0013-push-notifications.md`, `docs/security.md` #18 (surface: `hook.ts`, `external.ts` `Mirror.watching`) |
| Touch the desktop build / `DesktopShell` / `isMobile` gates | `docs/decisions/0015-desktop-client.md` (surface: `core/platform.dart`, `dashboard/presentation/desktop_shell.dart`, `notifications/data/push_service.dart`) |
| Touch the desktop workspace (tabs, split, palette, shortcuts) | `docs/proposals/24-desktop-workspace.md` (surface: `features/workspace/`, `ChatScreen`/`TerminalScreen` `onClose`) |
| Touch the spend ledger / `GET /spend` / the Usage page / saving tips | `docs/decisions/0017-spend-ledger.md`, `docs/protocols/session-rest.md` (GET /spend) (surface: `spend.ts`, `claude.ts`/`native.ts` result handling, `features/usage/`) |
| Touch the Max-plan meters / `GET /usage/plan` / the rail usage meter / pace tick | `docs/decisions/0020-plan-usage-sidebar.md`, `docs/protocols/session-rest.md` (GET /usage/plan) (surface: `usage.ts`, `features/usage/presentation/plan_usage_meter.dart`, `desktop_shell.dart`, `dashboard_screen.dart`) |
| Touch the prompt library (history, use counts, Improve prompt, chat's Improve sheet) or the prompting guide | `docs/decisions/0018-prompt-library-v2.md`, `docs/proposals/63-improve-from-chat.md`, `docs/prompting-guide.md` (surface: `prompts.ts`, `prompt-improve.ts`, `features/prompts/`) |
| Touch always-apply prompts / rule packs (Karpathy, Ambition), what is appended to every session's system prompt, or Improve's Go deeper mode | `docs/decisions/0031-always-apply-prompts.md`, `docs/proposals/61-rule-packs-and-go-deeper.md`, `docs/decisions/0026-session-rules-and-settings.md` (surface: `prompts.ts`, `settings.ts` `rulesForPrompt`, `db.ts` seeds, `prompt-improve.ts`, `claude.ts` `start`, `native.ts`, `features/prompts/`, `chat/presentation/context_sheet.dart`) |
| Touch the system monitor / `GET /system` / resource alerts | `docs/decisions/0019-system-monitor.md`, `docs/security.md` #20 (surface: `system.ts`, `push.ts` `system_alert`, `features/system/`, `push_note.dart` `systemAlertNote`) |
| Touch session-to-session messaging / the `vibe-peers` MCP tools | `docs/proposals/30-session-peer-tools.md`, `docs/security.md` #21 (surface: `peer-tools.ts`, `claude.ts` `mcpServers`/`peerRegistry`, `session-ws.ts` `getOrStart`) |
| Touch swarm tasks, file leases, `dispatch`, or the `list_tasks`/`claim_task`/`complete_task` tools | `docs/proposals/65-swarm-tasks-and-leases.md`, `docs/proposals/30-session-peer-tools.md`, `docs/protocols/session-rest.md` (Swarm tasks), `docs/security.md` #35 (surface: `tasks.ts`, `task-routes.ts`, `claude.ts` `canUseTool`, `peer-tools.ts`, `sessions.ts` `createSession`, `features/tasks/`) |
| Touch the swarm merge queue (`merge-queue*.ts`, `project-settings.ts`, `project-lock.ts`), the test command, `target_branch`, or `GIT_HARDEN_ARGS` / the git layout check | `docs/decisions/0032-swarm-merge-queue.md`, `docs/protocols/session-rest.md` (Merge queue), `docs/security.md` #34 + #36 (surface: `merge-queue.ts`, `merge-queue-routes.ts`, `project-settings.ts`, `project-lock.ts`, `git-run.ts`, `worktree.ts`, `server.ts` recovery; client: `app/lib/features/tasks/{data/task_api.dart,domain/merge_item.dart,presentation/merge_approval_screen.dart,presentation/project_settings_dialog.dart}`, `push_note.dart`) |
| Touch project notes / TODOs (`/projects/:id/notes`, the notes sheet) | `docs/proposals/31-project-notes.md`, `docs/protocols/session-rest.md` (surface: `notes.ts`, `scanner.ts` prune, `features/notes/`) |
| Touch the chat status line / `status` frame / `busy` on reattach | `docs/proposals/32-turn-status-line.md`, `docs/protocols/claude-ws.md` (surface: `turn-status.ts`, `claude.ts`/`native.ts` handle loops, `chat/domain/turn_status.dart`, `chat_session_controller.dart`, `chat_screen.dart` `_TurnStatusLine`) |
| Touch the permission gate / Auto-mode file scope / terminal input audit / failed-auth limit | `docs/security.md` #5 + #7, `docs/spikes/D18-spike-sdk-file-scope.md` (surface: `permission-gate.ts`, `file-scope.ts`, `input-audit.ts`, `app.ts` `authFailLimiter`) |
| Touch auth, command exec, or the ingress/transport     | `docs/security.md`, `docs/decisions/0005-tailscale-transport.md`, `PLAN.md §5` |
| Change the stack / add a major dependency              | `docs/decisions/0001-stack.md` (transport superseded by 0005) |
| Question why both engines exist                        | `docs/decisions/0002-hybrid-engine.md`          |
| Check what's done / what's next                        | `docs/milestones.md`                            |
| Re-run a spike                                          | the matching `docs/spikes/*.md` (has the run cmd) |
| Touch project files API / file save / upload / download | `docs/decisions/0030-project-file-writes.md`, `docs/proposals/59-project-files-transfer.md`, `docs/protocols/session-rest.md` (Project files), `docs/security.md` #33 — surface: `vibe-daemon/src/project-files.ts`, `browse.ts` |
| Touch the in-app code editor (open / edit / save a project file, highlighting, find/replace, 409 dialog, file tabs on desktop, the Windows editor window / `--editor`) | `docs/proposals/60-code-editor.md`, `docs/proposals/62-editor-window.md`, `docs/spikes/editor-package.md`, `docs/decisions/0030-project-file-writes.md`, `docs/protocols/session-rest.md` (Project files) — surface: `app/lib/features/editor/` (`window/` = editor-window IPC, tabs, app), `windows/runner/main.cpp` (title), `update/data/update_installer.dart` (quits the editor first), `files/data/project_files_api.dart`, `workspace/domain/work_tab.dart`, `chat/presentation/file_browser_screen.dart` `openChatFile` |
| Add / triage a Claude-session feature idea              | `docs/proposals/` (graduates to an ADR/protocol when accepted) |

## Conventions this project follows

- **Every unit of work gets a doc** in `/docs` (spike, decision, protocol,
  milestone step). Code references docs; docs reference `PLAN.md`.
- **Decisions** → an ADR in `docs/decisions/` (number, context, decision,
  consequences). Add a row to `docs/decisions/README.md`.
- **Spikes** → `docs/spikes/`, including the exact re-run command and findings.
- Keep `docs/milestones.md` and `docs/security.md` status columns current as
  work lands.

## Full index

See `docs/README.md`.
