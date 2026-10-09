# Work standard — how we plan, record and hand over work

One vocabulary for every project (ADR 0028). Seven things, one home each (six artifacts plus the Inbox). If a
thing isn't one of these, it isn't a file.

| Term | What it is | Where it lives | Lifetime |
|------|-----------|----------------|----------|
| **Roadmap** | The project's direction: goal, architecture, ordered **Milestones**, open questions. One per project. | `PLAN.md` | Living; edited in place |
| **Milestone** | One shippable chunk with done-criteria and a checkbox. A section of the Roadmap, never its own file. | `PLAN.md` § Milestones | Ticked when shipped |
| **Proposal** | One feature's design *before* it is built: problem, approach, surface touched, risks. | `docs/proposals/NN-title.md` | Status: `idea` → `accepted` → `building` → `shipped` (or `rejected`) |
| **Decision** | An accepted, hard-to-reverse choice (ADR): context, decision, consequences. | `docs/decisions/NNNN-title.md` | Immutable; supersede, don't edit |
| **Spike** | A throwaway experiment: question, exact re-run command, findings. | `docs/spikes/NN-title.md` | Immutable once written |
| **Task list** | The live checklist Claude keeps *during* one session. | Not a file (the session's todo list) | Gone when the session ends |
| **Inbox** | Unsorted ideas captured on the phone (the project's *Notes*). Triage turns each into a Proposal, a Milestone, a Task, or deletes it. Not a file in the repo. | VibeMobile → project → Notes; Claude reads it with `list_notes` | Until triaged |
| **Handoff** | End-of-session note for the next session: done, not done, next step, gotchas. | `docs/handoffs/YYYY-MM-DD-slug.md` | Written once; newest wins |

**"Plan" means one thing:** the steps Claude proposes for a single task in plan mode, for
you to approve. It is not stored. If it's worth keeping it becomes a Proposal (a feature) or
a Milestone (a chunk of the Roadmap). **Retired words:** session plan, build plan, TODO.md,
status doc, progress file.

## How a change flows

1. **Tiny** (a few lines, obvious) → just do it. No task list needed.
2. **Task** (clear, fits one session) → plan mode → approve → Task list → build → test.
3. **Feature** (new behaviour or surface) → **Proposal** `idea` → `accepted` → a **Decision**
   if it is hard to reverse or touches security → add a **Milestone** to the Roadmap →
   build → Proposal `shipped`, Milestone ticked, `.claude/docs-map.md` row added.
4. **Unknown** (does it even work?) → **Spike** first, then 2 or 3.
5. **Stopping with work left** → write a **Handoff** (don't leave state in chat).

## Starting a session
Read, in order: `CLAUDE.md`, the Roadmap's open Milestones, the newest Handoff in
`docs/handoffs/`, then the docs `.claude/docs-map.md` points to for the area.

## Keep sessions small — avoid auto-compaction
Auto-compaction is a lossy summary taken when the window is already full. A **Handoff** is the same
idea done on purpose: short, curated, in a file, read by a clean session.
- Start sessions by *reading* (Roadmap's open Milestones + newest Handoff), not by pasting history.
- Send exploration to the `scoper` subagent and big well-defined edits to `implementer`, so file
  reads stay out of the main context.
- At about 60% of the way to the compaction point the app offers **Write handoff & start fresh**:
  the session writes a Handoff, then a new chat resumes from it. Prefer it to "Compact now".

## Documentation depth
- A **Proposal** records what was built in its *What shipped* section (surface, files, tests).
- A **Decision** records why a hard-to-reverse choice was made. `git log` is the changelog.
- No separate changelog file. When a Milestone ships, it collapses to one ticked line that links its
  Proposal: `- [x] **M3 — name** — shipped 2026-10-08 → proposals/31-project-notes.md`. Keep the Roadmap
  small enough to read at session start (a few KB), with open Milestones in full.

## Rules
- Every unit of work gets a doc; code references docs, docs reference the Roadmap.
- Statuses are the exact words above — don't invent new ones.
- Never duplicate: a Milestone points to its Proposal; a Proposal points to its Decision.
- A Handoff carries unfinished Task-list items forward; unfinished *scope* goes back into the Roadmap.
- Handoff template: **State** (branch, last commit, tests) · **Done** · **Not done** ·
  **Next step** (one concrete action) · **Gotchas** · **Commands to resume**.
