# 64 — Swarm coding + prior-art survey (ranked ideas)

**Status:** accepted 2026-10-18 · nothing built yet; first step S1 + S2; merge queue (S3) in [ADR 0032](../decisions/0032-swarm-merge-queue.md) (proposed) · builds on proposals [19](19-multi-chat-grid.md), [28](28-worktree-per-session.md), [30](30-session-peer-tools.md), [ADR 0022](../decisions/0022-worktree-sessions.md), [ADR 0024](../decisions/0024-git-write-surface.md)

## Problem

Several chat sessions can already run in one project (cap `VIBE_MAX_CLAUDE`, default 6),
and each can get its own worktree (`.vibe-worktrees/<sessionId>`, branch `vibe/<sessionId>`).
They can also message each other via the vibe-peers tools. But nothing coordinates them:

- no shared task list: you split the work by hand, one chat at a time;
- no file ownership: two sessions sharing a checkout overwrite each other, and two
  worktrees conflict later at merge time;
- no path back to main: git-write stops at stage/commit/branch, and rebase and merge return 404;
- no awareness: a session doesn't learn what its peers changed, so it relies on stale assumptions.

"Swarm/hive coding" means letting N sessions work on one project at once without
stepping on each other. This doc surveys public prior art (checked 2026-10-18) and
ranks the ideas, both swarm and non-swarm.

## Main lesson from prior art

Every working system **splits the work so agents don't touch the same files, and merges in
one place, behind tests**. None of them solves two agents editing the same file at once.

- Claude Code agent teams docs: "Two teammates editing the same file leads to overwrites".
- Anthropic's multi-agent post: "most coding tasks involve fewer truly parallelizable tasks than research".
  It also reports about 15× the tokens of a single chat.
- Cognition ("Don't Build Multi-Agents"): "actions carry implicit decisions", so parallel
  writers make conflicting choices. Their 2026 follow-up (seen only via secondary sources)
  says what works is one writer per scope, with other agents reviewing and advising.
- Recent papers (the research agent found these; **check them before citing**):
  - "Passes Alone, Fails Together" (arXiv 2609.25396): patches that merge cleanly as text but
    break behaviour. Telling each agent about its peers' changes recovered most of the failures.
  - NP-Bench (arXiv 2610.07261): fixing non-overlapping scopes before work starts took clean
    integration from 1 of 9 scenarios to 9 of 9.

So the design is **isolate → scope → lease → merge queue → broadcast**, not real-time
co-editing. CRDT co-editing (e.g. "AgentRoom", arXiv 2608.23740) is out of scope.

## Prior-art catalogue

### Swarm and orchestration

| Project | How it works | What VibeMobile could take |
|---|---|---|
| [Claude Code worktrees](https://code.claude.com/docs/en/worktrees) | `claude -w`, subagent `isolation: worktree`, `git worktree lock` while running, stale sweep, `.worktreeinclude` copies gitignored files (e.g. `.env`) | Lock/sweep lifecycle and `.worktreeinclude` for our `.vibe-worktrees` |
| [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) (experimental) | Lead plus teammates; shared task list with deps; **claiming a task takes a file lock**; per-agent inbox files; `TaskCompleted` hooks can block | The data model. Note: teammates **aren't spawned in SDK mode**, so the daemon needs its own team layer |
| [Vibe Kanban](https://github.com/BloopAI/vibe-kanban) (~28k, now community-maintained) | Card = task, attempt = worktree + terminal + dev server; inline diff review → PR → merge; MCP server | The closest match to a phone UX: board → dispatch → review |
| [Gas Town](https://github.com/gastownhall/gastown) (~18k) | "Mayor" coordinator, "Polecat" workers in persistent worktrees, "Witness" watches for stuck agents, "Refinery" is a Bors-style merge queue that batches, runs gates and bisects | The most complete one-repo, many-agent design; the Witness and Refinery roles map onto daemon services |
| [mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail) (~2.2k) | Agent identities and inboxes; **advisory file leases** on globs with a time limit, exclusive or shared; a conflict is granted but reported; an optional pre-commit hook enforces | The lease model: fits our SQLite plus `peer-tools.ts` |
| [Beads](https://github.com/gastownhall/beads) (~28k) | Issue graph in Dolt; hash IDs (`bd-a1b2`) avoid merge collisions; `bd ready`; atomic `--claim` | Hash task IDs, a "ready" query, atomic claim |
| [Backlog.md](https://github.com/MrLesk/Backlog.md) (~7k) | Tasks are Markdown files in the repo with acceptance criteria and deps; one task per session, one PR per task | Matches our Proposals/Notes flow |
| [Task Master](https://github.com/eyaltoledano/claude-task-master) (~28k, slowing) | Splits a spec into a task graph with deps, over MCP | The planner/decompose step |
| [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) (~40k) | "Team" pipeline: plan → spec → execute → verify → fix loop | Staged workflow template |
| [claude-squad](https://github.com/smtg-ai/claude-squad), [ccmanager](https://github.com/kbwo/ccmanager), [parallel-code](https://github.com/johannesjo/parallel-code), [Nimbalyst](https://github.com/nimbalyst/nimbalyst) | tmux plus worktree per agent; busy/waiting/idle detection; mixed vendors; best-of-N compare | Session state badges; "run N, pick best" |
| [container-use](https://github.com/dagger/container-use) (~4.1k) | Container plus branch per agent; `cu diff/merge`; command log per environment | Optional sandbox for risky runs |
| [Ruflo / claude-flow](https://github.com/ruvnet/ruflo) (~76k) | Queen/worker "hive-mind"; names consensus protocols; vector memory | Little: heavy, claims unverified. Don't copy |

### Merging

| Project | What VibeMobile could take |
|---|---|
| [Mergiraf](https://codeberg.org/mergiraf/mergiraf) | Syntax-aware git merge driver (Tree-sitter: TS, Dart?, JSON, YAML…). Set it as the merge driver in each worktree; it falls back to normal conflict markers. **Check Dart support** |
| GitHub merge queue / Gas Town Refinery | Merge into main one change at a time: rebase → test → fast-forward; on failure, hand back to the author |
| [git-spice](https://github.com/abhinav/git-spice), Graphite | Stack a dependent task's branch on the branch it depends on |
| [jj](https://github.com/jj-vcs/jj) | Conflicts as first-class commits. A possible future direction only |

### Mobile/remote and adjacent

| Project | What VibeMobile could take |
|---|---|
| [Anthropic Remote Control](https://code.claude.com/docs/en/remote-control) | `--spawn worktree`, `--capacity`; push split into "needs action" vs "Claude chose to notify"; a presence file mutes pushes while you're at the machine. Anthropic now covers plain mobile chat (CUI archived because of it), so VibeMobile's edge is self-hosted, terminal, files and swarm |
| [Happy](https://github.com/slopus/happy) (~24k) | Voice-to-action; "ready to review" push; multiplayer sessions |
| [claude-remote-approver](https://github.com/yuuichieguchi/claude-remote-approver) | Approve / Always / Deny buttons on the notification, plus AskUserQuestion choices; timeout fallback |
| [Claude-Code-Remote](https://github.com/JessyTsui/Claude-Code-Remote) | Reply to the notification to continue |
| [ccusage](https://github.com/ryoppippi/ccusage), [Usage Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor), [Claude Code OTel](https://code.claude.com/docs/en/monitoring-usage) | 5-hour block, burn rate, "limit at HH:MM"; OTLP metrics and events |
| [disler observability](https://github.com/disler/claude-code-hooks-multi-agent-observability) | Live event timeline across sessions, a swim lane per agent |
| [code-server proxy](https://coder.com/docs/code-server/guide), [vibetunnel](https://github.com/amantus-ai/vibetunnel) | `/preview/<port>/` dev-server preview; terminal recording |
| [opcode](https://github.com/getAsterisk/opcode), [CloudCLI](https://github.com/siteboon/claudecodeui) | Saved custom agents; cost dashboard. Checkpoints we already have (ADR 0023) |

## Ranked ideas

Impact and feasibility are each rated H/M/L. Complexity: S ≈ 1 session, M ≈ 2–4, L ≈ a milestone.
🔒 marks a change that needs a `reviewer` pass (auth, exec or ingress).

### Swarm (build in order: each step is useful on its own)

**S1. Project task board + dispatch.** Impact H · Feasibility H · **M**
- **What:** each project gets tasks with deps, a file scope (globs), acceptance criteria and a
  state: `ready → claimed → running → review → merged`. On the phone, tap "Dispatch" to start a
  worktree session with the task as its first prompt.
- **Prior art:** Vibe Kanban, agent-teams task list, Beads (hash IDs, `ready`, atomic claim), Backlog.md.
- **Integration:**
  - SQLite `tasks` table; claims go through one `UPDATE … WHERE state='ready'`, which is atomic.
  - New vibe-peers tools `list_tasks` / `claim_task` / `complete_task`, so sessions can pull work themselves.
  - Notes triage can turn notes into tasks.
  - Client: new `features/tasks`; extend the multi-chat grid (proposal 19) with a task strip.

**S2. File leases.** Impact H · Feasibility H · **M** 🔒
- **What:** advisory leases on globs (exclusive or shared, with a time limit), granted automatically
  from the task's file scope or claimed through a peer tool.
- **Prior art:** mcp_agent_mail reservations; agent-teams file-lock claiming.
- **Integration:**
  - Unlike mcp_agent_mail's pre-commit hook, **we can enforce at tool-call time**. Every Edit/Write
    already passes through `permission-gate.ts`, and `file-scope.ts` already scopes paths.
  - If the path is under someone else's exclusive lease, the session gets a deny with the holder's
    name ("ask <session> via send_message"), or the phone gets an ask.
  - Leases are released on task complete or session end, and expire by TTL.
  - Bash writes slip through. That limit is acceptable and should be documented, as agent teams do.

**S3. Daemon merge queue.** Impact H · Feasibility M · **L** 🔒
- **What:** a task in `review` joins a FIFO queue. The daemon rebases its branch onto the target,
  runs the project's test command, and fast-forwards. On a conflict or a red test, the task goes
  back to the authoring session with the diff context, and the phone gets a push.
- **Prior art:** Gas Town Refinery, GitHub merge queue, Graphite; Mergiraf as the merge driver.
- **Integration:** this needs a **new ADR**. It goes beyond ADR 0024 (no rebase/merge today), and it
  writes to main, so the phone has to approve each merge by default. A per-project test command
  runs through the existing exec allowlist (proposal 60, phase 2).

**S4. Change broadcast.** Impact M–H · Feasibility H · **S**
- **What:** when the queue merges a task, every other running session in the project gets a short
  peer message: changed files and signatures, plus "rebase before continuing".
- **Prior art:** the STALE paper's recovery result; agent-teams mailboxes.
- **Integration:** reuse `send_message`/`pushUser` with a system sender, so it counts outside the
  per-sender rate limit.

**S5. Planner session.** Impact M · Feasibility M · **M**
- **What:** a "Plan swarm" action. One session splits a goal into S1 tasks with *non-overlapping
  file scopes* and deps, and the phone shows it for approval before anything is dispatched.
- **Prior art:** Task Master, oh-my-claudecode pipeline, NP-Bench up-front scoping.
- **Integration:** a prompt template plus a `create_tasks` peer tool; overlap check on the scope globs.

**S6. Swarm view + stuck-agent watcher.** Impact M · Feasibility H · **M**
- **What:** one screen showing tasks, lease holders, queue position, and each session's state
  (busy / waiting for you / idle / stuck > N min).
- **Prior art:** Gas Town Witness, ccmanager states, disler swim lanes.
- **Integration:** derived from S1–S3 tables plus the engine's turn state; a push when a session
  has sat idle or stuck for N minutes.

**S7. Best-of-N.** Impact M · Feasibility H once S1 exists · **S**
- **What:** dispatch one task to N worktrees and compare the diffs side by side, then keep one.
- **Prior art:** Nimbalyst.
- **Cost:** N× tokens, so it's opt-in.

Skip: Ruflo-style consensus protocols, CRDT co-editing, and native agent teams. The last needs
interactive CLI, not the SDK; only reconsider it if the SDK gains support.

### Non-swarm

| # | Idea | Prior art | Integration | Impact / Feas. / Size |
|---|---|---|---|---|
| O1 | Lock-screen approvals: Allow / Always / Deny and question choices as notification actions | claude-remote-approver, Remote Control | Push is content-free today (`{type, sessionId}`); the action fetches the pending item, then answers via the existing `permission` path. Make "require unlock" for Always the default | H / M / M 🔒 |
| O2 | Usage and limits screen: 5h block, burn rate, per project/model, "limit at HH:MM" push | ccusage, Usage Monitor, OTel | Extend the existing spend ledger (`spend.ts`, ADR 0017) with the 5h block and burn rate; `ccusage --json` or OTLP only if the ledger misses data | H / H / S–M |
| O3 | "Ready to review" and "presence" pushes: separate needs-action from FYI; mute while the desktop app is focused | Remote Control, Happy | `push.ts` types plus a desktop presence ping | M / H / S |
| O4 | Reply from the notification (Android RemoteInput) | Claude-Code-Remote | Sends a user turn into the session | M / H / S 🔒 |
| O5 | Watch PR → auto-fix CI failures and review comments | Remote Control cloud sessions | Poll `ci.ts`; on red, inject a turn into the owning session; pairs with S3 | M / M / M |
| O6 | Dev-server preview `/preview/<port>/` in a WebView | code-server, Vibe Kanban, vibetunnel | Localhost-only port allowlist behind the device token. **New ingress surface** | M / M / M 🔒 |
| O7 | Saved agents: system prompt + model + mode, one-tap launch (also used as S1 roles) | opcode, ccswarm roles | Extend the prompt library (ADR 0018) | M / H / S |
| O8 | Cross-session event timeline | disler observability | Engine events into a ring buffer; covered by S6 | L–M / H / M |
| O9 | Voice mode with on-device STT/TTS | Happy, Sled | Android speech APIs; nothing leaves the device | M / M / M |
| O10 | Terminal recording (asciinema) | vibetunnel | tmux `pipe-pane` to a cast file | L / H / S |

## Suggested order

1. **S1 + S2** together: a task board and leases make parallel sessions safe today, even with manual merges.
2. **S4**, then **S3**: the merge queue is the big one and needs an ADR.
3. **O2, O3, O1** can be done any time in parallel; they're small, high-value phone wins.
4. **S5, S6, S7** come after the core loop has been used for real.

## Decisions (2026-10-18)

- **Swarm tasks always run in a worktree.** A dispatched task always gets `worktree:true`.
  Leases don't catch Bash writes, so a shared checkout isn't safe. Leases then do a different
  job: they prevent conflicts between worktrees at merge time. A single, normal chat can keep
  using the shared checkout.
- **The test command lives in daemon project settings (SQLite), set from the phone,** never in a
  repo file. The merge queue runs it outside the permission gate, so an agent must not be able to
  choose it. It runs through the exec allowlist (proposal 60, phase 2). See ADR 0032 for the
  residual risk.
- **Up to 3 concurrent sessions per swarm by default,** adjustable up to `VIBE_MAX_CLAUDE`.
  The swarm screen shows the running cost from the existing spend ledger (ADR 0017).
- **Mergiraf is optional.** Use it when it's installed, and check Dart with `mergiraf languages`.
  Files it doesn't support use plain git merge.
- **Swarm is Claude-engine only in v1.** Peer tools stay Claude-only; revisit later.
- **Every merge to main needs approval from the phone by default.** A per-project auto-merge
  switch can come later.
- **Build order:** S1 + S2 together, then S4, then S3, which follows ADR 0032.

## Caveats

- Star counts and activity were checked 2026-10-18.
- Not verified: parruda/claude-swarm (404), Conductor and Cursor internals (closed source),
  Ruflo's benchmark, Cognition's 2026 follow-up (secondary sources only), and the arXiv papers
  (abstracts only; confirm before citing).
