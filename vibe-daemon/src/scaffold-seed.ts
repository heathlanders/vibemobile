// The default seeded scaffold: "Foundations (generic)" — a project-agnostic copy
// of how this repo is set up (CLAUDE.md behavioral guidelines + the docs
// skeleton + conventions), with VibeMobile specifics stripped. Applied to a new
// project dir on create (projects.ts). {{project_name}} and {{date}} are
// token-substituted at write time.

export type ScaffoldFile = { path: string; body: string };

const CLAUDE_MD = `# CLAUDE.md — {{project_name}}

How Claude works in this repo. Behavioral guidelines (from Andrej Karpathy's
observations on LLM coding pitfalls), plus project specifics.

**Tradeoff:** these guidelines bias toward caution over speed. For trivial tasks,
use judgment.

---

## Behavioral guidelines

### 1. Think Before Coding
**Don't assume. Don't hide confusion. Surface tradeoffs.**
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First
**Minimum code that solves the problem. Nothing speculative.**
- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" that wasn't requested.
- No error handling for impossible scenarios.

Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes
**Touch only what you must. Clean up only your own mess.**
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- Remove orphans YOUR changes created; leave pre-existing dead code (mention it).

The test: every changed line should trace directly to the request.

### 4. Goal-Driven Execution
**Define success criteria. Loop until verified.**
- "Add validation" → "write tests for invalid inputs, then make them pass".
- "Fix the bug" → "write a test that reproduces it, then make it pass".
- For multi-step tasks, state a brief plan with a verify step each.

---

## Work standard

Full text: \`docs/WORKFLOW.md\`. Six artifact types, one home each — **Roadmap** (\`PLAN.md\`,
with its **Milestones**), **Proposal**, **Decision** (ADR), **Spike**, **Task list** (live in a
session, never a file), **Handoff** (\`docs/handoffs/\`); the phone's Notes are the **Inbox**
(read them with the \`list_notes\` tool; tick one off with \`resolve_note\` once it is in the docs). "Plan" means plan mode only and is not stored. Start a session by reading the open Milestones and the newest Handoff; end one with
unfinished work by writing a Handoff.

## Project context

{{project_name}} — _one-line description. See \`PLAN.md\` for architecture._

**Docs:** every unit of work (spike, decision, protocol, milestone step) gets a
doc in \`/docs\`. \`/docs\` is the source of truth; \`.claude/docs-map.md\` routes
you to the right doc for a given change.

**Where things live:** repos in \`/data/projects\`, caches/tools in \`/data/cache\`,
models in \`/data/models\`, Docker data in \`/data/docker\`. Never create a cache or
data directory on \`/\` (the root SSD is small). New tool paths go in
\`~/.config/data-paths.env\`. Keep the pnpm store and repos on the same filesystem.
`;

const PLAN_MD = `# {{project_name}} — Plan

_Created {{date}}._

## 1. Goal

_What this project is and who it's for._

## 2. Architecture

_The moving parts and how they connect._

## 3. Milestones

_Ordered shippable chunks, riskiest unknowns first. One checkbox each; link its Proposal.
Tick when shipped. Statuses and flow: \`docs/WORKFLOW.md\`._

- [ ] **M1 — _first milestone_** — done when: _criteria_. Proposal: _link_.

## 4. Open questions / risks

_What's still undecided._
`;

const DOCS_MAP = `# Docs map (Claude-facing)

Derived from \`/docs\`. Tells Claude **which doc to read for which work**, so
\`/docs\` stays the source of truth and \`CLAUDE.md\` stays lean.

> Maintenance: when you add/relocate a doc under \`/docs\`, add a row here.

## Read before you…

| When you're about to…        | Read first |
|------------------------------|------------|
| _add a row as docs land_     | _the matching doc_ |

## Conventions this project follows

- **Every unit of work gets a doc** in \`/docs\` (spike, decision, protocol,
  milestone step). Code references docs; docs reference \`PLAN.md\`.
- **Decisions** → an ADR in \`docs/decisions/\` (number, context, decision,
  consequences). Add a row to \`docs/decisions/README.md\`.
- **Spikes** → \`docs/spikes/\`, including the exact re-run command and findings.
- **Roadmap / Milestones** → \`PLAN.md\`. **Handoffs** → \`docs/handoffs/\`. Vocabulary and
  flow: \`docs/WORKFLOW.md\`.
`;

const DOCS_README = `# Docs — {{project_name}}

Source of truth for this project. Every unit of work lands here.

- \`proposals/\` — speculative feature ideas (idea → accepted → building → shipped).
- \`decisions/\` — ADRs (accepted, numbered, immutable once decided).
- \`protocols/\` — wire/interface specs.
- \`spikes/\` — throwaway experiments + their findings and re-run command.
- \`handoffs/\` — end-of-session notes for the next session (\`YYYY-MM-DD-slug.md\`).
- \`WORKFLOW.md\` — the work standard: how we plan, record and hand over work.

\`.claude/docs-map.md\` is the Claude-facing routing table; this file is the
human index.
`;

const PROPOSALS_README = `# Proposals

Speculative feature docs. **Not** decisions yet — an idea lives here until
accepted, then graduates to an ADR (\`../decisions/\`) and/or a protocol spec
(\`../protocols/\`), and its row points at the result.

| # | Proposal | Touches | Status |
|---|----------|---------|--------|
| — | _first idea_ | — | idea |

Status: \`idea\` → \`accepted\` → \`building\` → \`shipped\`.
`;

const DECISIONS_README = `# Decisions (ADRs)

One file per accepted decision: \`NNNN-short-title.md\`. Each states **context**,
**decision**, **consequences**. Immutable once accepted — supersede with a new
ADR rather than editing.

| # | Decision | Status |
|---|----------|--------|
| — | _first decision_ | — |
`;

const WORKFLOW_MD = `# Work standard — how we plan, record and hand over work

One vocabulary for every project. Seven things, one home each (six artifacts plus the Inbox). If a
thing isn't one of these, it isn't a file.

| Term | What it is | Where it lives | Lifetime |
|------|-----------|----------------|----------|
| **Roadmap** | The project's direction: goal, architecture, ordered **Milestones**, open questions. One per project. | \`PLAN.md\` | Living; edited in place |
| **Milestone** | One shippable chunk with done-criteria and a checkbox. A section of the Roadmap, never its own file. | \`PLAN.md\` § Milestones | Ticked when shipped |
| **Proposal** | One feature's design *before* it is built: problem, approach, surface touched, risks. | \`docs/proposals/NN-title.md\` | Status: \`idea\` → \`accepted\` → \`building\` → \`shipped\` (or \`rejected\`) |
| **Decision** | An accepted, hard-to-reverse choice (ADR): context, decision, consequences. | \`docs/decisions/NNNN-title.md\` | Immutable; supersede, don't edit |
| **Spike** | A throwaway experiment: question, exact re-run command, findings. | \`docs/spikes/NN-title.md\` | Immutable once written |
| **Task list** | The live checklist Claude keeps *during* one session. | Not a file (the session's todo list) | Gone when the session ends |
| **Inbox** | Unsorted ideas captured on the phone (the project's *Notes*). Triage turns each into a Proposal, a Milestone, a Task, or deletes it. Not a file in the repo. | VibeMobile → project → Notes; Claude reads it with \`list_notes\` and ticks a note off with \`resolve_note\` once it is in the docs | Until triaged |
| **Handoff** | End-of-session note for the next session: done, not done, next step, gotchas. | \`docs/handoffs/YYYY-MM-DD-slug.md\` | Written once; newest wins |

**"Plan" means one thing:** the steps Claude proposes for a single task in plan mode, for
you to approve. It is not stored. If it's worth keeping it becomes a Proposal (a feature) or
a Milestone (a chunk of the Roadmap). **Retired words:** session plan, build plan, TODO.md,
status doc, progress file.

## How a change flows

1. **Tiny** (a few lines, obvious) → just do it. No task list needed.
2. **Task** (clear, fits one session) → plan mode → approve → Task list → build → test.
3. **Feature** (new behaviour or surface) → **Proposal** \`idea\` → \`accepted\` → a **Decision**
   if it is hard to reverse or touches security → add a **Milestone** to the Roadmap →
   build → Proposal \`shipped\`, Milestone ticked, \`.claude/docs-map.md\` row added.
4. **Unknown** (does it even work?) → **Spike** first, then 2 or 3.
5. **Stopping with work left** → write a **Handoff** (don't leave state in chat).

## Starting a session
Read, in order: \`CLAUDE.md\`, the Roadmap's open Milestones, the newest Handoff in
\`docs/handoffs/\`, then the docs \`.claude/docs-map.md\` points to for the area.

## Keep sessions small — avoid auto-compaction
Auto-compaction is a lossy summary taken when the window is already full. A **Handoff** is the same
idea done on purpose: short, curated, in a file, read by a clean session.
- Start sessions by *reading* (Roadmap's open Milestones + newest Handoff), not by pasting history.
- Send exploration to the \`scoper\` subagent and big well-defined edits to \`implementer\`, so file
  reads stay out of the main context.
- At about 60% of the way to the compaction point the app offers **Write handoff & start fresh**:
  the session writes a Handoff, then a new chat resumes from it. Prefer it to "Compact now".

## Documentation depth
- A **Proposal** records what was built in its *What shipped* section (surface, files, tests).
- A **Decision** records why a hard-to-reverse choice was made. \`git log\` is the changelog.
- No separate changelog file. When a Milestone ships, it collapses to one ticked line that links its
  Proposal: \`- [x] **M3 — name** — shipped 2026-10-08 → proposals/31-project-notes.md\`. Keep the Roadmap
  small enough to read at session start (a few KB), with open Milestones in full.

## Rules
- Every unit of work gets a doc; code references docs, docs reference the Roadmap.
- Statuses are the exact words above — don't invent new ones.
- Never duplicate: a Milestone points to its Proposal; a Proposal points to its Decision.
- A Handoff carries unfinished Task-list items forward; unfinished *scope* goes back into the Roadmap.
- Handoff template: **State** (branch, last commit, tests) · **Done** · **Not done** ·
  **Next step** (one concrete action) · **Gotchas** · **Commands to resume**.
`;

// "Foundations (generic)" — order matters only for readability. Empty dirs ship
// via .gitkeep so the skeleton survives a fresh git tree.
export const FOUNDATIONS_FILES: ScaffoldFile[] = [
  { path: "CLAUDE.md", body: CLAUDE_MD },
  { path: "PLAN.md", body: PLAN_MD },
  { path: ".claude/docs-map.md", body: DOCS_MAP },
  { path: "docs/README.md", body: DOCS_README },
  { path: "docs/proposals/README.md", body: PROPOSALS_README },
  { path: "docs/decisions/README.md", body: DECISIONS_README },
  { path: "docs/WORKFLOW.md", body: WORKFLOW_MD },
  { path: "docs/handoffs/.gitkeep", body: "" },
  { path: "docs/protocols/.gitkeep", body: "" },
  { path: "docs/spikes/.gitkeep", body: "" },
];
