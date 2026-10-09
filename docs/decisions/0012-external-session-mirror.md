# ADR 0012 — Mirror and reply to a `claude` CLI session still running on the server

**Status:** Accepted (2026-09-27).

## Context

The operator works from VS Code (Remote-SSH) on a client PC, running `claude` in
the integrated terminal on the server. Discovery ([session-rest.md](../protocols/session-rest.md#external-sessions-discovery))
already lists those sessions on the phone and lets the phone **continue** one,
but only after the CLI exits: two writers on one transcript is unsafe, so the
daemon must not resume a session (Agent SDK subprocess) the CLI still owns.

The ask: see the **same, still-running** session on the phone, live, and act on
it when needed (add context, answer questions, approve a prompt).

Constraints found on the box:

1. **A running CLI announces itself.** Claude Code writes
   `~/.claude/sessions/<pid>.json` = `{pid, sessionId, cwd, procStart, status:
   busy|idle, …}`. `procStart` is field 22 of `/proc/<pid>/stat` (verified), so a
   reused pid can be told apart. The format is **undocumented/internal** —
   everything built on it must fail soft (read-only degrades to today's
   behaviour). The file also names a `messagingSocketPath`; we deliberately do
   **not** use that private peer protocol.
2. **The transcript is live.** `~/.claude/projects/<enc>/<sessionId>.jsonl`
   grows line by line as the CLI works; the existing `parseTranscript` already
   maps it to our `messages` shape.
3. **A plain terminal can't be typed into from outside.** `TIOCSTI` is disabled
   (kernel ≥ 6.2), and the VS Code pty belongs to VS Code. Input needs the CLI to
   run inside something we can address — tmux.
4. **The daemon's own tmux (`-L vibe`, ADR 0004) lives in the daemon's systemd
   cgroup** (`KillMode=control-group`). A CLI session placed on that server would
   die on a daemon restart.

## Decision

**Read side (any running CLI, tmux or not):** when the phone attaches
(`WS /session/:id`) to a row whose `claude_session_id` is a *running* CLI session
(registry entry + live pid + matching `procStart`, and **not a child of the
daemon** — its own Agent SDK subprocess registers there too, `entrypoint:
sdk-ts`; treating that as external stopped the live loop on every reattach), the daemon does **not** start
the Agent SDK. It enters **mirror mode**: re-imports `messages` from the
transcript (canonical while the CLI owns it), sends `history`, then tails the
file and streams new turns in the normal claude-ws frames, plus an `external`
frame carrying `busy|idle` and whether replying is possible. When the CLI exits
(or the pid's session changes, e.g. `/clear`), the daemon closes the socket
`4410`; the client's reconnect lands on the normal path and resumes via the SDK.

**Write side (only `vc` sessions):** a `vc` shell function runs
`tmux -L vc new-session -s vc-<dir>[-n] claude`. A **dedicated socket** `-L vc`
that the daemon **never starts** — it only lists, pastes and attaches — so the
server lives in the operator's login session, not the daemon's cgroup (4). A
running CLI is repliable iff a pane on `-L vc` whose session name starts `vc-`
has `pane_pid` == the CLI pid. Then:

- `{t:"user", text}` → `load-buffer` (stdin) + `paste-buffer -p` (bracketed
  paste, so multi-line text arrives as one message) + `send-keys Enter`.
- `{t:"interrupt"}` → `send-keys Escape`.
- `WS /session/:id/tty` → a node-pty `tmux -L vc attach -t =vc-…` using the pty-ws
  wire (ADR 0003), for anything the transcript can't show — permission prompts,
  menus. **No `detach-client`** (unlike `/pty/:id`): the PC's client must stay.

## Security (security.md #16)

- **No client-supplied target.** The tmux session is resolved server-side from
  the row's `claude_session_id` → registry pid → pane; the client sends only a
  session row id. Re-resolved on **every** input, never cached.
- **Scoped:** only `vc-` sessions on the `-L vc` socket, only when the CLI's
  `cwd` is the row's project path and inside `projectRoots()` (`pathInRoots`).
  Other tmux sessions (the operator's own, `-L vibe`) are unreachable.
- **argv only** (`execFile`, no shell); text goes via stdin to `load-buffer`, never
  argv, so it can't become a tmux command or key name.
- **Audited:** `external.input`, `external.interrupt`, `external.tty` events with
  the device id. Not new *capability*: `WS /pty/:id` already gives the paired
  device a shell as the same user; this reaches a process the operator
  explicitly opted in (by starting it with `vc`).
- Mirror mode is read-only on the filesystem outside our own DB.

## Consequences

- The operator types `vc` instead of `claude`. Bonus: the session survives a VS
  Code disconnect (`vc` re-attaches).
- The phone never runs a second writer on a live transcript.
- Built on an internal Claude Code file format; if it changes, mirror mode
  silently stops engaging and the old stop-then-continue flow remains.
- ~~Image attachments aren't sent into a running CLI session (text only).~~
  Since 2026-10-06 (user-approved write surface, security.md #8), a reply's
  images are exported to a private 0700 dir as 0600 files. Each path is then
  pasted as its own bracketed paste, which the CLI turns into `[Image #N]`.
  Verified on a real `claude` CLI in a throwaway tmux pane, with nothing sent.
  Files are swept after 24 h.
- Pending permission prompts don't appear in the transcript; the app's
  Terminal view is the way to answer them. AskUserQuestion does appear, and is
  answered from the app (addendum 2026-10-06).

## Addendum (2026-10-03) — titles and multiple sessions

- **Several `vc` sessions per dir already work:** `vc 1`, `vc 2`, … name the tmux
  session `vc-<dir>-<n>`. Reply routing matches on the CLI's `pane_pid`, not the
  name, so nothing daemon-side limits it to one.
- **Naming:** the session title is the CLI's own `ai-title` transcript entry
  (latest wins, applied only while `title_auto=1`), not the first user message.
  Same undocumented-format caveat as the sessions registry: absent ⇒ falls back
  to ADR 0009's heuristic.

## Addendum (2026-10-06) — answer AskUserQuestion from the app

The CLI writes the `AskUserQuestion` `tool_use` to the transcript **before** the
user answers, so a mirror sees the question while the TUI shows its menu.
Mirror mode now sends it as the same `user_dialog` frame the SDK path uses (the
app's question card renders it unchanged, `dialogId` = the tool_use id), and
types the answer into the `vc` pane.

**Menu key map** (spike on Claude Code 2.1.291, `tmux -L vcspike`, Haiku):

| Shape | Keys | Observed |
|---|---|---|
| 1 question, single-select | option digit | selects and submits at once |
| single-select, more questions follow | option digit | selects and moves to the next question |
| multi-select | each digit toggles `[✔]`, then `Tab` | `Tab` moves on (or to Submit) |
| >1 question, or any multi-select | … then `1` | review screen: `1. Submit answers` |
| "Type something" | its digit focuses a text field | pasted newlines are dropped; not used |
| cancel | `Escape` | — |

Each key is its own `send-keys`, 150 ms apart (`VIBE_VC_KEY_DELAY_MS`), so the
TUI never reads two keys as one input. Verified end to end: `questionKeys` +
`realVcTmux` drove a live two-question (multi + single) menu to the right answers.

Rules: free text isn't typed (the app's card offers labels only; use the
Terminal view); the transcript is re-read right before typing, and a question
already answered on the PC is skipped. Only digits, `Tab`, `Escape` and `1` are
sent, never `Enter`, so a stale answer can at worst leave digits in the CLI's
input box. If the CLI changes its menu keys, answers land wrong. The Terminal
view is the fallback, and the spike table above is what to re-check.
