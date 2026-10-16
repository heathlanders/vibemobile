# Architecture Decision Records (ADRs)

One file per locked decision. Format: context → decision → consequences.
Status: `Accepted` until superseded.

| ADR  | Decision                          | Status   |
|------|-----------------------------------|----------|
| 0001 | [Stack](0001-stack.md)            | Accepted (transport superseded by 0005) |
| 0002 | [Hybrid engine](0002-hybrid-engine.md) | Accepted |
| 0003 | [PTY↔WS wire protocol](0003-pty-ws-wire-protocol.md) | Accepted |
| 0004 | [tmux-backed PTY](0004-tmux-backed-pty.md) | Accepted |
| 0005 | [Tailscale transport](0005-tailscale-transport.md) | Accepted |
| 0006 | [Project create write surface](0006-project-create-write-surface.md) | Accepted |
| 0007 | [Model-agnostic gateway](0007-model-agnostic-gateway.md) | Accepted |
| 0008 | [Native multi-provider engine](0008-native-engine.md) | Accepted |
| 0009 | [Auto-titled chat sessions](0009-auto-session-title.md) | Accepted |
| 0010 | [Session tree read surface (`@file`)](0010-session-tree-read-surface.md) | Accepted |
| 0011 | [Git surface (read-only status; write deferred)](0011-git-surface.md) | Accepted |
| 0012 | [Mirror + reply to a running CLI session](0012-external-session-mirror.md) | Accepted |
| 0013 | [Push notifications (approvals, questions, done)](0013-push-notifications.md) | Accepted |
| 0014 | [Push for CLI sessions via a Claude Code hook](0014-cli-session-push-hook.md) | Accepted |
| 0015 | [Desktop client from the same Flutter codebase](0015-desktop-client.md) | Accepted |
| 0016 | [Model registry for every major provider, agent CLI presets, hand-off](0016-model-registry-and-agent-presets.md) | Accepted |
| 0017 | [Token/cost ledger and usage dashboard](0017-spend-ledger.md) | Accepted |
| 0018 | [Prompt library v2: history, usage counts, "Improve prompt"](0018-prompt-library-v2.md) | Accepted |
| 0019 | [Read-only system monitor and low-resource alerts](0019-system-monitor.md) | Accepted |
| 0020 | [Always-on Max-plan usage meter (5h / weekly + pace)](0020-plan-usage-sidebar.md) | Accepted |
| 0021 | [Session image read surface (chat image preview)](0021-session-image-read-surface.md) | Accepted |
| 0022 | [Worktree-per-session (isolated copy)](0022-worktree-sessions.md) | Accepted |
| 0023 | [File checkpoint / rewind](0023-checkpoint-rewind.md) | Accepted |
| 0024 | [Git write surface: hardening, stage, commit, branch (no push)](0024-git-write-surface.md) | Accepted |
| 0025 | [Storage layout: `/data` is the default for repos, caches, Docker](0025-storage-layout.md) | Accepted |
| 0026 | [Session rules and storage settings](0026-session-rules-and-settings.md) | Accepted |
| 0027 | [Scheduled prompts (unattended runs)](0027-scheduled-prompts.md) | Accepted |
| 0028 | [One work-management vocabulary (Roadmap, Proposal, Decision, Spike, Task list, Handoff, Inbox)](0028-work-management-standard.md) | Accepted |
| 0029 | [Pair a new device from an already-paired one](0029-pair-from-a-paired-device.md) | Accepted |
| 0030 | [Project file writes and transfer](0030-project-file-writes.md) | Accepted |

New decision? Copy the shape of an existing ADR, bump the number, add a row.
