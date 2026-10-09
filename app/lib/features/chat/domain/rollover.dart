// "Write handoff & start fresh" (ADR 0028): instead of letting a long session auto-compact
// (lossy, at a full window), the session writes a Handoff file on purpose and a new chat
// resumes from it. Pure strings → unit-tested.

/// Share of the way to the compaction point (or the window) at which the app offers it.
const double freshNudgeAt = 0.6;

/// Sent to the CURRENT session. Falls back sensibly when a project has no WORKFLOW.md.
const String handoffInstruction =
    'Write a Handoff for this session to docs/handoffs/YYYY-MM-DD-<slug>.md (follow docs/WORKFLOW.md if it exists). '
    'Sections: State (branch, last commit, tests passing?), Done, Not done, Next step (one concrete action), '
    'Gotchas, Commands to resume. Move unfinished scope into the Roadmap (PLAN.md) as Milestones. '
    'Commit the file, then reply with just its path.';

/// First turn of the fresh session.
const String resumeInstruction =
    'Start by reading CLAUDE.md, the open Milestones in PLAN.md, and the newest file in docs/handoffs/. '
    'Then tell me in a few lines where we left off and propose the next step. Do not start building until I agree.';
