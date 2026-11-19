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

- **Q1** (2026-11-19). `.github/workflows/ci.yml` on PR and push to main: `app` (Flutter
  3.44.1 as in `release-windows.yml`; pub get, analyze, test) and `daemon` (Node 18 as the box's
  unit runs today; tmux installed; git identity set; `npm ci`, `npm test`). The one analyzer info
  in `claude_socket.dart` fixed so analyze exits 0. First run on PR #44: both jobs green. Not done:
  making the checks required on main is a repo setting left to the owner (PLAN line). Not
  verified: a deliberately failing test turning the run red.
- **Q2** (2026-11-19). `vibe-daemon/tsconfig.json` (`strict`, `noEmit`, NodeNext) and
  `npm run typecheck`, now a CI step before `npm test`. 57 errors at first: production code was
  clean except for missing `ws` types (added `@types/ws`); the rest were test typings (narrow fake
  signatures, `unknown` inject payloads, an `assert.equal(x, null)` narrowing), fixed without
  changing behaviour. `src/spike-*.ts` is excluded until R12 moves the spikes out. Box note:
  npm runs with `NODE_ENV=production` here, so a plain `npm install` prunes dev types; use
  `npm install --include=dev` to typecheck locally.
- **Q4** (2026-11-19). `release.sh` bumps `pubspec.yaml`, builds the APK, and only then commits,
  tags and pushes; a failed APK build restores `pubspec.yaml` and exits with nothing committed or
  tagged. A failed or missing Windows run prints the exact `git push --delete origin vX && git tag
  -d vX` (nothing is published at that point). `release.sh --rollback x.y.z` repoints
  `latest.json` at the retained files for x.y.z, with the build number read from tag vx.y.z.
  Clients only move to a higher build, so a rollback stops a bad build spreading but does not
  downgrade phones that already have it. Test: `scripts/release-test.sh` (scratch clone, local
  bare origin, `FLUTTER=/bin/false`): old script pushed the tag, new one leaves none; rollback
  writes the right version/build/sha. Runs in CI as `release-script`. A `--skip-apk` release still
  tags before the Windows build, as before.
- **Q3** (2026-11-19, WS frames). `src/ws-frames.ts`: a zod discriminated union for the chat
  socket's 11 client frame types (`parseClientFrame`) and the PTY resize body (`parseResize`, used
  by `/pty` and `/tty`). Anything else is dropped before a handler runs. Real bug it closes: a frame
  of JSON `null`, a number or an array made `f.t` throw inside the `ready.then` callback, an
  unhandled rejection per frame. Value checks that need session state (mode whitelist, MCP server
  names, effort levels) stay where they were. Tests: `session-ws.test.ts` (non-object and
  mistyped frames, no rejection, socket keeps working; red on old code), `ws-frames.test.ts`
  (shape table). Route bodies are next, as files are touched.
- **Q5** (2026-11-19). 23 widget tests, no `lib/` change, no bug found:
  `pairing_screen_test.dart` (form; empty code makes no request; 401 shows the server error and
  stores nothing; unreachable server; good code stores creds and re-reads `credsProvider`, against a
  real local server), `update_install_test.dart` (checksum match/mismatch/404 at `UpdateApi`;
  controller no-ops on an unsupported platform; `UpdateDialog` install / error + Retry / progress /
  manual Windows download / Later; `UpdateHost` asks only when newer), `terminal_screen_test.dart`
  (unreachable → connecting banner, never Live; close X confirm; no close on the CLI tty view).
  Gap: `UpdateController` reads `Platform.isAndroid/isWindows` directly, so its real
  "newer build → install → error" path can't run on the Linux test host without making the platform
  injectable; the installers (`OpenFilex`, `Process`, `exit`) are untested. Written by the
  `implementer` agent, reviewed and re-run here (548/548, analyze clean).
