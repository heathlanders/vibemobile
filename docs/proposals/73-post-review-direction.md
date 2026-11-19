# 73 — Direction after the 2026-11-19 review: personal tool, build only what is different

**Status:** idea 2026-11-19 · research summary + candidate features; nothing accepted to build yet

## Decision context

VibeMobile is a personal tool. It is not for sale and not competing for users. That removes the
distribution gaps (store build, iOS, web client, no-VPN relay, team features) from the list.

## What exists (checked 2026-11-19)

| Product | Overlap with VibeMobile |
|---------|-------------------------|
| [Claude Remote Control](https://code.claude.com/docs/en/remote-control) | Start/steer sessions on your own box from the official apps; push approvals, diff pane, worktrees, cross-session messaging, schedules. No phone shell; transcripts on Anthropic's servers; subscription login only. |
| [Paseo](https://github.com/getpaseo/paseo) | Open source, phone/web/desktop, many agents, terminal, relay or Tailscale. |
| [Happy](https://github.com/slopus/happy) | Open source, E2E encrypted Claude/Codex client, voice agent. |
| [Orca](https://github.com/stablyai/orca) | Agent fleet over SSH, line comments on diffs, browser preview. |
| [CC Pocket](https://github.com/K9i-0/ccpocket) | Same architecture (Flutter + Node bridge + Tailscale), Claude + Codex. |
| [CloudCLI](https://github.com/siteboon/claudecodeui) | Web UI with files, git, shell, several agents. |

Plain mobile chat for Claude Code is covered by first-party software. Parity features there
(messaging, schedules, slash-command coverage) will keep being overtaken.

## What VibeMobile has that the others do not (as far as checked)

- Shell + chat on the phone with no third-party relay; transcripts stay on the box.
- Swarm enforcement: file leases checked at tool-call time, merge queue with phone approval.
- The daemon owns sessions, so they outlive the `claude` process and the client.

## Rule going forward

Fix the base first (proposals 68–72 and the verification sweep). After that, a new feature needs
one of: (a) the owner misses it weekly, or (b) it deepens one of the three differences above.
"A competitor has it" is not a reason.

## Candidates (unranked until the owner picks; each needs its own proposal)

| Idea | Who has it | Note |
|------|-----------|------|
| Dev-server preview through the daemon (proxy a project's local port to the app) | Orca, Paseo, Claude Desktop | Was O6 in proposal 64. New ingress surface → ADR + `reviewer`. |
| Inline comments on a diff, sent back to the session as the next turn | Orca, Paseo, Vibe Kanban | Builds on the existing diff viewer; client-mostly. |
| Subagent progress view | Remote Control, Orca | SDK already emits subagent events; today they render as tool rows. |
| Git push + PR create from the app | Paseo, Orca | Excluded by ADR 0024; would need a superseding ADR. |
| Structured Codex/Gemini chat (approvals, diffs) instead of raw terminal presets | Happy, Paseo, Orca, CC Pocket | Large. Check whether running Paseo beside the daemon covers it before building. |
| More than one server | Remote Control, Happy, Paseo, Orca | Only if a second box appears. |
| Voice conversation mode | Happy, Paseo | Dictation exists (proposal 01). |

## Unverified

Happy's current feature set, Paseo's licence, and whether any competitor has lease enforcement
were not confirmed.
