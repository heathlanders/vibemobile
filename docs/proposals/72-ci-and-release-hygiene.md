# 72 — CI, typecheck and release hygiene

**Status:** accepted 2026-11-19 · from the 2026-11-19 project review · `.github/workflows`, `vibe-daemon/` config, `scripts/release.sh`

## Problem

About 1,150 test cases exist and none run on a pull request. Facts gathered 2026-11-19 (v1.0.40).

| # | Finding | Where |
|---|---------|-------|
| Q1 | CI runs only a leak scan and the Windows build. No `flutter analyze`, `flutter test`, typecheck or `npm test`. | `.github/workflows/leak-scan.yml`, `release-windows.yml` |
| Q2 | The daemon has no `tsconfig.json`; `tsx` strips types, so type errors are never reported. No lint. | `vibe-daemon/` |
| Q3 | Request bodies and WS frames are hand-cast (`row: any` in `session-ws.ts`); zod is only used for MCP/native tools. | `vibe-daemon/src/session-ws.ts` |
| Q4 | `release.sh` commits, tags and pushes before building. A failed build leaves a pushed tag. No rollback step. | `scripts/release.sh:39-55` |
| Q5 | No integration test; no tests reference `PairingScreen`, `UpdateInstaller` or `TerminalScreen`. | `app/test/` |
| Q6 | No LICENSE file in a public repo. | repo root |
| Q7 | `docs/proposals/README.md` uses statuses outside its own vocabulary ("built", "code + tests done"), and 23 proposals wait on an on-device check. | `docs/proposals/README.md` |

## Proposal

1. **Q1.** New workflow `ci.yml` on PR and push to main, two jobs: `app` (`flutter analyze`,
   `flutter test`, Flutter pinned to the version in `release-windows.yml`) and `daemon`
   (`npm ci`, `npm test`, Node pinned to what the box runs). Daemon tests spawn tmux and git —
   install tmux in the job. Make the checks required on main.
2. **Q2.** Add `vibe-daemon/tsconfig.json` (`strict`, `noEmit`) and a `typecheck` script. Expect
   errors: fix real bugs, and where the count is large, land the config with the failing files
   listed in `exclude`, then shrink the list. Add `typecheck` to CI once it is clean.
3. **Q4.** Reorder `release.sh`: bump + build APK first, then commit, tag, push. On Windows-build
   failure print the exact commands to delete the tag. Add `release.sh --rollback x.y.z` that
   repoints `latest.json` at a retained older build.
4. **Q3.** Zod schemas for incoming WS frames in `session-ws.ts` and `pty-ws.ts` first (the crash
   surface), then route bodies as files are touched. No big-bang rewrite.
5. **Q5.** Widget tests for pairing, update install decision, and terminal connect/close.
6. **Q6.** Owner picks a license (or states "all rights reserved" in the README). Decision, not code.
7. **Q7.** Tracked in the Roadmap milestone "On-device verification sweep", not here.

## Acceptance

- A PR with a failing Dart test or failing daemon test is red.
- `npm run typecheck` exits 0 in CI.
- `release.sh` dry run with a forced APK build failure leaves no tag.
- LICENSE question answered in the README.

## What shipped

(fill in per step)
