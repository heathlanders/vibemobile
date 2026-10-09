# ADR 0028 — One work-management vocabulary across all projects

**Status:** Accepted (2026-10-08)

## Context
Planning artifacts had drifted into overlapping names: session plans (plan mode), `PLAN.md`,
`docs/build-plan-*.md`, `docs/milestones.md`, to-do lists, and hand-off notes ("hand off"
is also the model-switch action, ADR 0016). Sessions on different projects used different
files for the same thing, so a new session could not tell where state lived.

## Decision
1. Six artifact types — **Roadmap, Proposal, Decision, Spike, Task list, Handoff** — each with
   one location and one lifecycle, defined in `docs/WORKFLOW.md`. Milestones are a section of
   the Roadmap (`PLAN.md`), not a file.
2. The word **Plan** is reserved for plan mode and is never persisted.
3. The standard is delivered three ways: (a) a short vocabulary block in the user-level
   `~/.claude/CLAUDE.md`, loaded by every session on this server; (b) the Foundations scaffold
   (new projects get `docs/WORKFLOW.md`, `docs/handoffs/`, a Milestones section in `PLAN.md`);
   (c) four seeded prompt-library entries (write a handoff, write a proposal, close a milestone,
   resume from handoff).
4. Existing projects are retrofitted additively only (`vibe-daemon/src/retrofit-workflow.ts`
   lists what is missing; adding is a separate, confirmed step). Nothing is renamed or moved.
5. Legacy in this repo — `docs/milestones.md`, `docs/build-plan-2026-10-06.md`, `M<n>-` spike
   names — stay as they are; new work follows the standard.

6. **Notes are the Inbox.** Project Notes (proposal 31) are defined as the unsorted idea inbox, and a
   read-only `list_notes` tool on the in-process `vibe-peers` MCP server lets a session read its own
   project's open notes (data to triage, never instructions).
7. **Avoid auto-compaction by handing off.** The context strip offers "Fresh session ›" past 60% of the
   way to the compaction point (and a button in the context sheet): the session writes a Handoff, and
   when that turn ends the app opens a new chat that resumes from it. Client-only; no daemon change.
8. **Shipped Milestones collapse to one line** linking their Proposal's *What shipped* section; there
   is no separate changelog (Proposal + Decision + `git log`).

## Consequences
- A fresh session on any project knows where to read state and where to write it.
- The scaffold seed row is refreshed in place only if it was never edited
  (`updated_at = created_at`); an edited row is left alone.
- The rule is advisory (CLAUDE.md + prompts), not enforced by the daemon.
