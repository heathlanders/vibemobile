# VibeMobile — /docs

Running record of **everything we build**. Source of truth for decisions,
spikes, and protocols as they happen.

## How the docs relate to the rest of the repo

| File / dir            | Role                                                            |
|-----------------------|----------------------------------------------------------------|
| `PLAN.md` (root)      | The master plan — goal, architecture, milestones. Stable.      |
| `docs/`               | The running record — what we actually did, decided, proved.    |
| `.claude/docs-map.md` | Claude-facing index: which doc to read for which kind of work. |
| `CLAUDE.md` (root)    | How Claude behaves in this repo.                               |

**Rule:** every unit of work (a spike, a decision, a protocol, a milestone
step) gets a doc here. Code references docs; docs reference `PLAN.md`.

## Layout

```
docs/
  README.md            this file
  WORKFLOW.md          the work standard: Roadmap / Proposal / Decision / Spike / Task list / Handoff / Inbox
  milestones.md        legacy status tracker (new work: Milestones live in PLAN.md, ADR 0028)
  handoffs/            end-of-session notes for the next session (YYYY-MM-DD-slug.md)
  security.md          PLAN §5 checklist, tracked
  prompting-guide.md   prompting + token-saving practices (feeds Improve prompt)
  spikes/              one doc per spike (what we proved + how to re-run)
  decisions/           ADRs — one per locked decision
  protocols/           wire-format specs (WS framing, etc.)
  ops/                 operational logs for the host (what was done, how to verify/roll back)
```

## Index

- **Work standard (read first):** [WORKFLOW.md](WORKFLOW.md)
- **Milestones:** [milestones.md](milestones.md)
- **Prompting & saving tokens:** [prompting-guide.md](prompting-guide.md)
- **Security checklist:** [security.md](security.md)
- **Spikes:**
  - [M0 spike 1 — Agent SDK auth](spikes/M0-spike1-agent-sdk-auth.md)
  - [M0 spike 2 — PTY↔WS round-trip](spikes/M0-spike2-pty-ws-roundtrip.md)
  - [M5 spike — gateway model swap](spikes/M5-spike-gateway-model-swap.md)
  - [M6 spike — native engine](spikes/M6-spike-native-engine.md)
  - [M7 spike — SDK plan mode](spikes/M7-spike-plan-mode.md)
  - [M8 spike — SDK file checkpointing + rewind](spikes/M8-spike-checkpoint-rewind.md)
  - [M9 spike — extended thinking stream](spikes/M9-spike-thinking.md)
  - [M10 spike — session rules in the system prompt](spikes/M10-spike-session-rules.md)
  - [M11 spike — reasoning effort](spikes/M11-spike-effort.md)
  - [M12 spike — context window + compaction](spikes/M12-spike-context-compact.md)
  - [M13 spike — slash commands and skills](spikes/M13-spike-slash-commands.md)
  - [M14 spike — branching a conversation](spikes/M14-spike-fork.md)
  - [M15 spike — MCP servers](spikes/M15-spike-mcp.md)
  - [D18 spike — which file reads reach canUseTool](spikes/D18-spike-sdk-file-scope.md)
- **Decisions (ADRs):** [decisions/README.md](decisions/README.md)
- **Protocols:**
  - [PTY↔WS wire protocol](protocols/pty-ws.md)
  - [Terminal reattach](protocols/reattach.md)
  - [Claude session WS](protocols/claude-ws.md)
  - [Session REST](protocols/session-rest.md)
  - [Crash capture](protocols/crash-capture.md)
- **Ops logs:**
  - [2026-10-07 — Root disk cleanup and `/data` migration](ops/2026-10-07-root-disk-cleanup.md)
- **Build plan (2026-10-06):** [build-plan-2026-10-06.md](build-plan-2026-10-06.md)
- **Proposals (Session/Claude features):** [proposals/README.md](proposals/README.md)
