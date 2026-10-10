# Proposals — Session / Claude features

Speculative feature docs. **Not** decisions or protocols yet — an idea lives here
until accepted, then graduates to an ADR (`decisions/`) and/or protocol spec
(`protocols/`), and its row points at the result.

Scope: features layered on the Claude session engine
([`protocols/claude-ws.md`](../protocols/claude-ws.md), Agent SDK). Each doc names
its wire/schema impact so promotion to a protocol is mechanical.

| # | Proposal | Touches | Status |
|---|----------|---------|--------|
| 01 | [Voice input → prompt](01-voice-input.md) | client only (`user` frame) | shipped (on-device STT mic → composer, edit-first) |
| 02 | [Diff viewer + swipe approve](02-diff-viewer.md) | `permission_request.diffPreview` (new optional field), `diff-preview.ts` | shipped (server-built preview = render==execution; collapsed diff in the card; swipe with 0.55 threshold + confirm on Bash/Write; audit unchanged) → [claude-ws.md](../protocols/claude-ws.md#diff-preview-proposal-02), security.md #5 |
| 03 | [Cost / token meter](03-cost-meter.md) | `result` frame, `events` | shipped (sessions.total_cost_usd; live header badge) |
| 04 | [Session templates](04-session-templates.md) | `POST /sessions`, `prompts` | shipped 2026-10-06 (client only: `template` tag + project "Start from template") |
| 05 | [Background continue + FCM](05-background-continue.md) | session lifecycle, FCM | idea |
| 06 | [Message copy / export](06-message-copy.md) | client only (clipboard, share) | shipped (copy bubble + copy transcript; share-sheet 2026-10-06 via `share_plus`) |
| 07 | [Tool output rendering](07-tool-output.md) | `tool_result` frame, `messages` | shipped (tool_result frame; folded on tool row; expandable under chip) |
| 08 | [Permission card displayName](08-permission-displayname.md) | `permission_request` render | shipped |
| 09 | [Stop / interrupt](09-stop-interrupt.md) | `interrupt` frame, SDK abort | shipped (interrupt frame → Query.interrupt; composer stop toggle) |
| 10 | [Message search](10-message-search.md) | `GET /sessions/:id/messages` | shipped (server LIKE + in-chat search results; jump-to-message 2026-10-06) |
| 11 | [Retry / edit last turn](11-retry-edit-turn.md) | client (`user` frame) | shipped (long-press retry/edit; superseded dimmed, client-only marking) |
| 12 | [Session rename / tags](12-session-rename-tags.md) | `PATCH /sessions/:id`, `sessions` | shipped (rename + CSV tags column; tag chips + filter in list) |
| 13 | [Scroll-to-bottom + unread](13-scroll-unread.md) | client only | shipped (auto-scroll gated on at-bottom; FAB + unread badge) |
| 14 | [Jump to permission](14-jump-to-permission.md) | client only | shipped (haptic + "Approval needed" FAB when scrolled up) |
| 15 | [initialPrompt atomicity](15-initialprompt-atomicity.md) | `POST /sessions` | shipped (new claude sessions; primed + cleared on first attach) |
| 16 | [Image / screenshot input](16-image-input.md) | `user` frame, `POST /sessions/:id/attachments`, `messages` | shipped (picker + OS share-target) → [claude-ws.md](../protocols/claude-ws.md#attachments-image-input), [session-rest.md](../protocols/session-rest.md#attachments-image-input-claude-sessions) |
| 17 | [New project + foundations scaffold](17-new-project-scaffold.md) | new `scaffolds` table, `POST /projects`, `/scaffolds` CRUD, filesystem write + git shell-out | shipped (daemon → [ADR 0006](../decisions/0006-project-create-write-surface.md), security.md #9; client → dashboard "New project" FAB + foundation library) |
| 18 | [Auto-allow permissions + no AskUserQuestion timeout](18-auto-allow-permissions.md) | `auto_allow` frame, `canUseTool`, settings toggle | shipped (default ON; audited `permission.auto_allow`) → [claude-ws.md](../protocols/claude-ws.md#permissions-securitymd--highest-scrutiny), security.md #5 |
| 19 | [Multi-chat grid](19-multi-chat-grid.md) | client (`multichat/` feature, shared controller), `VIBE_MAX_CLAUDE` default | shipped (up to 6 live tiles; tap → full ChatScreen on the same socket; cap 4→6) |
| 20 | [Session file viewer](20-session-file-viewer.md) | `GET /sessions/:id/file-edits[/diff]`, `GET /sessions/:id/file`, `diff` dep | shipped (changed-files sheet + diff/file screen; E2E-verified vs live SDK session) → [session-rest.md](../protocols/session-rest.md#file-edits-session-file-viewer), security.md #12 |

| 21 | [Motion & polish foundation](21-motion-polish.md) | client only (`core/widgets.dart`, `Motion` tokens, all push sites) | shipped (skeletons, entrances, blinking stream cursor, gate/banner transitions, page routes; hero deferred) → [DESIGN.md §9](../../app/DESIGN.md) |
| 22 | [Composer slash commands, prompt insert + `@file`](22-composer-commands.md) | client composer + `GET /sessions/:id/tree` | shipped (`/prompt` with `{{var}}` fill, `/files`, `/copy`, `/stop`; `@file` mentions → [ADR 0010](../decisions/0010-session-tree-read-surface.md), security.md #13) |
| 23 | [Project cockpit: activity, cost, devices, audit log](23-project-cockpit.md) | client models + `GET /events`, `current` on `GET /devices` | shipped (last_active + sort, session cost in lists, device revoke from the app, audit-log viewer; git status/commit/push deliberately excluded → own ADR) → security.md #14 |
| 24 | [Desktop workspace (session cockpit)](24-desktop-workspace.md) | client only (ADR 0015 phase 1) | shipped (code): sidebar, tabs + split, changes pane, Ctrl+K palette, Enter-to-send, drag-drop attach |
| 25 | [Session modes: Ask / Auto-allow / Plan](25-permission-modes.md) | `mode` frame both ways, `POST /sessions {mode}`, `sessions.mode`, `exit_plan` `user_dialog`, composer chip + `/mode` | shipped (on-device walkthrough pending) → [claude-ws.md](../protocols/claude-ws.md#modes-proposal-25), [spike](../spikes/M7-spike-plan-mode.md), security.md #5 |
| 26 | [Collapsed tool runs + clipboard image paste](26-tool-run-grouping-and-paste.md) | client only; adds `pasteboard` dep | shipped (code): consecutive tool calls fold into one expandable row; desktop Ctrl+V attaches clipboard images |
| 27 | [Checkpoint / rewind a turn's file edits](27-checkpoint-rewind.md) | SDK `enableFileCheckpointing` + `rewindFiles`, new `POST /sessions/:id/rewind` (write surface) | accepted (ADR 0023) |
| 28 | [Git worktree per Claude session](28-worktree-per-session.md) | `POST /sessions {worktree}`, first git write (extends ADR 0011) | accepted (ADR 0022) |
| 29 | [Connectivity & runtime diagnostics](29-health-diagnostics.md) | `GET /system` `diagnostics` block (tailscale status, Node version), `system_alert` | shipped 2026-10-06 |
| 30 | [Session-to-session tools (peer messaging)](30-session-peer-tools.md) | in-process MCP server `vibe-peers` (`peer-tools.ts`), `peer.send` audit event; no wire change | shipped (daemon): list/send/read between sibling sessions; same project, Ask/Auto/Plan-aware, rate-limited → security.md #21 |
| 31 | [Project notes / TODO list](31-project-notes.md) | new `notes` table + `notes.ts` CRUD, scanner prune guard, `features/notes/` (sheet on mobile, dialog on desktop) | building: code + tests done 2026-10-06, device check pending |
| 32 | [Turn status line](32-turn-status-line.md) | new WS `status` frame (`turn-status.ts`, both engines), sent on attach + phase change + 5 s heartbeat; `_TurnStatusLine` above the composer | building: code + tests done 2026-10-06, real-session check pending |
| 33 | [Images in chat](33-chat-images.md) | `tool_result.images` (tool-result image blocks → attachments), new `GET /sessions/:id/image` ([ADR 0021](../decisions/0021-session-image-read-surface.md)), `chat_image.dart` strip + fullscreen viewer | building: code + tests done 2026-10-06, real-session check pending → security.md #23 |
| 34 | [Chat links](34-chat-links.md) | `link_spans.dart`, `linkified_text.dart`, `url_launcher` (external browser, http/https only) | code + tests done 2026-10-07, on-device tap check pending |
| 35 | [Markdown in assistant messages](35-chat-markdown.md) | `markdown.dart` (pure parser), `markdown_text.dart`; assistant bubbles only; no new dependency | code + tests done 2026-10-07, on-device visual check pending |
| 36 | [Thinking blocks](36-thinking-blocks.md) | `thinking` option + `thinking_delta`/`thinking` frames, `thinking` history role, `ThinkingTile` | built 2026-10-07, on-device visual check pending |
| 37 | [Switch model mid-session](37-live-model-switch.md) | `set_model` / `model` frames, `ClaudeSession.setModel` → `Query.setModel`; fixes a string-content crash in `handle` | built 2026-10-07, on-device check pending |
| 38 | [Terminal key row](38-terminal-key-row.md) | `terminal_key_row.dart`, `ctrl_latch.dart`; mobile only, no server change | built 2026-10-07, on-device check pending |
| 39 | [Reasoning effort control](39-effort-control.md) | `set_effort` / `effort` frames, `sessions.effort`, `EffortSheet`; start option + `applyFlagSettings` | built 2026-10-07, on-device check pending |
| 40 | [Context meter and compaction](40-context-meter-compact.md) | `context` / `compacted` frames, `compact` command, `notice` history role, `ContextStrip`/`ContextSheet` | built 2026-10-07, on-device check pending |
| 41 | [Skills and slash commands in the composer](41-slash-commands.md) | `commands` frame, `commands.ts`, `matchCommands`; skills + project commands under `/` | built 2026-10-07, on-device check pending |
| 42 | [Branch a conversation](42-branch-conversation.md) | `POST /sessions/:id/fork`, `fork.ts` (`planFork`), `BranchSheet`; SDK `forkSession` + stored `sdk_uuid` | built 2026-10-07, on-device check pending |
| 43 | [Tools & integrations (MCP)](43-mcp-view.md) | `get_mcp` / `mcp_action` / `mcp` frames, `mcp.ts`, `McpSheet`; config never forwarded; hooks deliberately not built | built 2026-10-07, on-device check pending |
| 45 | [Pull request & CI status](45-pr-ci-status.md) | `GET /sessions/:id/ci`, `ci.ts` (read-only `gh pr list` / `gh run list`), `CiSheet` | built 2026-10-07, on-device check pending |
| 46 | [Read-only file browser](46-file-browser.md) | `GET /sessions/:id/browse[/file]`, `browse.ts` (root-confined, secrets/.git hidden, text-only), `FileBrowserScreen` | built 2026-10-07, on-device check pending |
| 47 | [Collapse large pastes in the composer](47-paste-collapse.md) | client only: composer `TextInputFormatter`, chip tokens expanded on send, collapsed long user bubbles | accepted 2026-10-10 |
| 48 | [File paths in chat open in the app](48-chat-file-links.md) | client: `FileLink` span in `link_spans.dart`/`markdown.dart` → existing `browse/file` + `FileViewerScreen`; no new daemon surface | building: code + tests done 2026-10-10, on-device check pending |
| 49 | [Desktop workspace in a non-maximized window](49-responsive-desktop.md) | `DesktopShell` chosen by platform not width; compact rail/sidebar below 1000 px | building: code + tests done 2026-10-10, Windows on-device check pending |

Status: `idea` → `accepted` → `building` → `shipped` (then move detail to the ADR/protocol).
