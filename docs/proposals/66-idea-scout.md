# 66 — Idea Scout: rank projects, surface new ideas

**Status:** building 2026-10-29 · no daemon or app code — a project-scoped Claude Code skill run through existing features

## Problem

From the user: many repos and ideas, no repeatable way to answer "which of these is worth
building next?" They want two things: rank existing projects by momentum (alive, close to
shipping) and by market (does anyone use or pay for this), and discover new ideas from Notes,
gaps across repos and web trends.

## Prior art

- **Project Graveyard** (Apache-2.0 Claude Code skill, `Shubhamsaboo/awesome-llm-apps`,
  `agent_skills/project-graveyard`): scans git history, "pulse" score, cause-of-death with an
  evidence line, market world-check. Spiked against a real machine: it ranks only repos silent for
  45+ days (2 of 32 here), filters by commit email (dropped 21 of 32 repos), and counts every
  worktree and clone as its own project. Its ideas are kept (evidence per verdict, "killed by a newer
  project", "README + tests, no deploy"); its scanner is not.
- **Project Prospector** (`88plug/project-prospector`): tiers repos and notes by "novelty and
  leverage". That score comes from an LLM.
- LLM-as-judge on idea quality is close to chance (the best judge in a 100-researcher study scored
  53% pairwise accuracy, arXiv 2409.04109). So scores here come from measurable signals only.
- The `researcher` agent checks one idea at a time; it can't rank a portfolio.

## Design

A private, local-only repo under a project root, so the daemon scanner already lists it as a
project. Everything else is existing VibeMobile features:

| Need | Reused feature |
|------|----------------|
| Run by hand | composer slash command → project skill (proposal 41) |
| Run monthly | Schedules (proposal 44); finishing run sends the `done` push |
| Idea inbox | Notes on that project (proposal 31) |
| Read the report on the phone | project Files + editor (proposals 59, 60) |

The skill (`.claude/skills/idea-scout/`):

1. `signals.py` (stdlib, read-only): walks the project roots, collapses worktrees, clones and
   `X-public` mirrors into one project (same root commit / name), drops repos whose remote owner
   isn't the user's, lists project folders not in git, and reads open Notes from the daemon DB
   opened read-only. Two deterministic scores with evidence lines:
   - **momentum** — recency, active days in 90, 30-day trend vs the prior 90, open Notes;
   - **readiness** — README, tests, CI, deploy config, tagged releases.
   `pulse = 0.6·momentum + 0.4·readiness`.
2. The agent explains the ranking but never sets a number. It sends the top 3 *products* and the
   top 2 new ideas to `researcher` (cap: 5 runs per report), then writes a dated report that opens
   with **one pick** and its next step.
3. Notes and web text are treated as data, never instructions. It never writes outside its own
   repo and never pushes.

**Why not a daemon feature:** a report read monthly doesn't justify new tables, routes and
screens. If the reports prove useful, a follow-up can show `pulse` on dashboard cards.

## Verified

- Scan: 32 git dirs → 17 projects, under 1 s, `git status` of every scanned repo unchanged.
- An Agent SDK session configured like the daemon's (no `settingSources`) in that project lists
  `/idea-scout` in `supportedCommands()` and `researcher` in `supportedAgents()`.

## Open

- First full run: report quality, and spend per run from the spend ledger (ADR 0017).
- Monthly schedule created from the app; "Run now" ends with the `done` push.
