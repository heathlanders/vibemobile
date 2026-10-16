# Protocol — Claude session WS

The wire between the Agent SDK (server, `src/claude.ts`) and the Flutter chat UI
for a `kind=claude` session. **JSON text frames** (unlike the raw-bytes terminal
channel, [pty-ws.md](./pty-ws.md)).

Builds on / required by:
[session-rest.md](./session-rest.md) (creation) ·
[reattach.md](./reattach.md) (drop-detect, reuse the same loop) ·
`spikes/M0-spike1-agent-sdk-auth.md` (the SDK event shape).

## Endpoint

```
WS /session/:id          (:id = the sessions-row id, kind must be 'claude')
```

Reached over the tailnet (`tailscale serve`, ADR 0005) as
`wss://<machine>.<tailnet>.ts.net/session/:id`. **Bearer token required** — the
global auth hook gates the upgrade (401 ≈ client `4401`). Attach-only: the
session is created out-of-band via `POST /sessions {kind:'claude'}`.

**Model selection ([ADR 0007](../decisions/0007-model-agnostic-gateway.md)):** the
model is chosen at create (`POST /sessions {kind:'claude', model}` — the phone
picks from `GET /models`), stored on the row, and applied once when the SDK starts
(`ClaudeSession.start` → `options.model`, plus the gateway `env` when
`VIBE_GATEWAY_URL` is set). The effective model comes back in the `init` frame
below. Switching model = a new session; there is no mid-session model frame.

**Two engines, one wire ([ADR 0008](../decisions/0008-native-engine.md)):** these
frames are served by whichever engine the model's provider selects
(`session-ws.getOrStart`) — `ClaudeSession` (Agent SDK) for anthropic, or
`NativeSession` (Vercel AI SDK) for `openai`/`google`, which run those models
natively. The frame contract is identical, so the client is engine-agnostic, with two
native differences: the native `init` **omits `claudeSessionId`** (native is
stateless — resume is transcript replay, not a resumable server session), and
`AskUserQuestion`/`user_dialog` are **Claude-only** (native `dialog_response` is a
no-op). Tool approvals go through the **same** shared `PermissionGate` in both, so the
auto-allow / deny / timeout / audit rules below are identical regardless of engine.

## Lifecycle (mirrors the terminal, [reattach.md](./reattach.md))

| Event | Action |
|-------|--------|
| WS connect | row exists & `kind=claude`? no → close `4404`. Resuming a non-live row (discovered/stale) when live claude rows are already at `VIBE_MAX_CLAUDE` → `error` frame + close `4429` (client stops, no retry). yes → get-or-start the `ClaudeSession` from the in-daemon registry (resume the Agent SDK via `claude_session_id` if seen before), `attach(ws)` |
| WS close | **detach** — the SDK query loop keeps running for the next reattach. Never stop here. Several clients may be attached at once (phone + desktop) and **every attached client receives every frame**; `detach(ws)` removes only that socket |
| `DELETE /sessions/:id` | `ClaudeSession.stop(4404)` (abort the SDK, close every attached socket) + remove rows |
| `stop()` | Closes every attached socket so no client keeps talking to a dead session: `1012` (default — idle reaper, Mirror takeover; the client retries and resumes), `4404` (session deleted; client stops), `4404` also for a worktree missing (4410 would make the client retry) |

Durability differs from tmux: the loop lives **in the daemon process**, not a
detached server process. Reconnect within the daemon's lifetime re-attaches the
live loop; across a daemon restart the loop is gone but the next attach resumes
from the persisted transcript (SDK `~/.claude/projects` + our `messages` table).

**Resuming an externally-started session:** a row discovered from a `claude`
CLI transcript ([session-rest.md](./session-rest.md#external-sessions-discovery))
has a `claude_session_id` but an empty `messages` table. Its first attach
backfills `messages` from that transcript (`transcript-import.ts`) before
`ClaudeSession.start` resumes — same `resume: claude_session_id` path as any
other reattach — so `history` on that attach shows the full prior conversation.
The daemon never resumes while that CLI is still running — it mirrors instead
(below).

**Mirroring a CLI session that is still running** ([ADR 0012](../decisions/0012-external-session-mirror.md)):
if the row's `claude_session_id` belongs to a live `claude` process (Claude
Code's `~/.claude/sessions/<pid>.json`, pid + `procStart` checked), WS connect
does **not** start the Agent SDK (any in-daemon loop for the row is stopped — it
would be a second writer). Instead (`external.ts` `Mirror`):

1. `messages` is rebuilt from the transcript → `history`, `title?`, then
   `external {status, canReply}`.
2. The transcript is tailed (1 s poll, complete lines only) → `assistant`,
   `tool_use`, `tool_result`, and `user_turn` for user text (typed on the PC, or
   the phone's own reply echoed back). No `delta`/`init`/`result`/`usage`;
   `external` re-sent when the CLI flips `busy`↔`idle`.
3. Client `user` → pasted into the CLI's tmux pane + Enter; `interrupt` → Escape.
   Only when `canReply` (started with `vc`, see ADR 0012); otherwise an `error`
   frame and nothing is typed. `images`, `permission`, `auto_allow`, `mode` are
   ignored — permission prompts live in the CLI's TUI (`/tty` below).
   **AskUserQuestion:** a transcript `tool_use` named `AskUserQuestion` with no
   result yet → `user_dialog {dialogId: <tool_use id>, dialogKind:
   'ask_user_question', payload: input}` (also sent after `external` when
   attaching to a CLI that is already waiting). The client's `dialog_response`
   (same `answers` contract as below) is typed into the CLI's menu as keys
   (`questionKeys`, ADR 0012 addendum); `completed:false` → Escape. Answers that
   aren't offered labels (free text) → `error` + the `user_dialog` re-sent,
   nothing typed. When the `tool_result` lands (answered here or on the PC) →
   `dialog_closed {dialogId}`. Audited `external.dialog`.
4. CLI exits (or its session id changes, e.g. `/clear`) → close **`4410`**. The
   client retries as for any drop; the reattach finds no running CLI and takes
   the normal resume path.

**`WS /session/:id/tty`** — the running `vc` session's own terminal, pty-ws wire
([pty-ws.md](./pty-ws.md): `'0'`+keys, `'1'`+resize JSON; raw bytes back). A
second tmux client next to the PC's (no `detach-client`); close = detach.
`4404` when the row has no repliable running CLI. Audited `external.tty`.

## Frames

### Client → server
| `t` | Fields | Meaning |
|-----|--------|---------|
| `user` | `text`, `images?` (`string[]` of attachmentIds) | A user turn — pushed into the SDK input stream. `images` reference blobs uploaded out-of-band (see Attachments); the server inflates each into an SDK image content block |
| `permission` | `toolUseID`, `allow` (bool) | Answer a pending tool-approval request |
| `mode` | `mode` (`'ask'`\|`'auto'`\|`'plan'`) | Switch the session mode ([proposal 25](../proposals/25-permission-modes.md), see [Modes](#modes-proposal-25)). The daemon whitelists the name and maps it to an SDK permission mode itself; anything else is dropped. **Not** sent on attach — the daemon is the source of truth |
| `auto_allow` | `on` (bool) | **Legacy** (proposal 18) — kept for old clients: `on` → `auto`, off → `ask`. Never moves a session out of `plan`. Turning it on flushes any pending `permission_request` as an allow |
| `dialog_response` | `dialogId`, `completed` (bool), `result?` | Answer a `user_dialog` (e.g. AskUserQuestion). `completed:false` cancels — the SDK then applies the dialog's default. For `exit_plan`: `result: {approve, mode?, feedback?}` (see Modes) |
| `interrupt` | — | Cancel the in-flight turn without ending the session ([proposal 09](../proposals/09-stop-interrupt.md)). The turn finalizes with a `result` |
| `set_model` | `model` (string) | Switch the session's model for subsequent turns ([proposal 37](../proposals/37-live-model-switch.md)). Claude engine only; a native-provider id, an invalid id, the current model, or one the SDK rejects is **ignored** (no `model` frame). Success is signalled by a `model` frame |
| `set_effort` | `effort` (`'low'`\|`'medium'`\|`'high'`\|`'xhigh'`\|`'max'`\|`null`) | Change reasoning effort for subsequent turns ([proposal 39](../proposals/39-effort-control.md)); `null` = the model's default. Claude engine only; an unknown level, the current one, or an SDK refusal is **ignored** (no `effort` frame). Persisted in `sessions.effort` |
| `compact` | — | Compact the conversation now ([proposal 40](../proposals/40-context-meter-compact.md)): the daemon streams `/compact` to the SDK. Ignored while a turn is running, after `stop`, or before the engine started. Claude engine only |
| `get_mcp` | — | Ask for the session's MCP servers ([proposal 43](../proposals/43-mcp-view.md)); answered with an `mcp` frame. Claude engine only |
| `mcp_action` | `server` (string), `action` (`'reconnect'`\|`'enable'`\|`'disable'`) | Reconnect / turn on / turn off one MCP server **of this session**. Ignored unless `server` is a name the SDK itself lists; audited `session.mcp` with the outcome; always followed by a fresh `mcp` frame |

### Server → client
| `t` | Fields | Meaning |
|-----|--------|---------|
| `history` | `messages[]` (`{id, role, content, tool_json, images?, ts}`; `id` = the daemon message id — what `POST /sessions/:id/rewind` takes) | Sent first on **every** attach — the persisted transcript. The chat analog of tmux redraw. `images` on a user message = attachmentIds; the client lazy-fetches each via `GET /attachments/:id` to redraw the thumbnail. **Capped** (`history.ts`): the newest ≤600 rows within ~1.5 MB, with tool inputs/results truncated to 4000 chars and bodies to 20k; `omitted` = how many older rows were left out (they stay in the DB). An uncapped replay reached 35 MB and crashed the phone |
| `init` | `claudeSessionId`, `model` | SDK session started/resumed; id captured for resume |
| `mode` | `mode`, `available` (`string[]`) | The session's current mode. Sent right after `history` on every attach and after every change. `available` = `['ask','auto','plan']` for Claude sessions, `['ask','auto']` for native (no Plan). Absent for mirrored CLI sessions (the CLI owns its mode) |
| `delta` | `text` | A token chunk of the current assistant turn (streamed) |
| `assistant` | `text` | The finalized assistant text (settles the streamed bubble; persisted) |
| `tool_use` | `id`, `name`, `input` | Claude is invoking a tool (for display) |
| `tool_result` | `toolUseID`, `content`, `isError`, `images?` | A tool's output, keyed to its `tool_use` ([proposal 07](../proposals/07-tool-output.md)); also folded onto the stored tool row so `history` replays it. `images` = attachment ids for image blocks in the result (≤4, same sniff + size gate as uploads; fetch via `GET /attachments/:id`) — [proposal 33](../proposals/33-chat-images.md). Also sent for a mirrored CLI session; never by the native engine. Omitted when none |
| `permission_request` | `toolUseID`, `toolName`, `title`, `displayName`, `description`, `input`, `diffPreview?` | **Approve/deny on the phone** before the tool runs. `diffPreview` (optional, `Edit`/`Write`/`MultiEdit` only) carries the pending change as a unified diff — see [Diff preview](#diff-preview-proposal-02) |
| `user_dialog` | `dialogId`, `dialogKind`, `payload`, `toolUseID?` | A blocking dialog the CLI asked the host to render (AskUserQuestion). Forwarded opaquely; answer with `dialog_response` |
| `result` | `subtype` (+ `cost`, `sessionCost` on the **native** path only) | End of turn. Native (pay-per-token) sessions carry the real `total_cost_usd` and running `sessionCost`; the Agent SDK path omits them — on a Max subscription the token→dollar figure is fiction, so real usage rides the `usage` frame instead. The cost is still accumulated in the `sessions.total_cost_usd` column for audit |
| `status` | `running` (bool), `phase?` (`thinking`\|`writing`\|`tool`\|`waiting`), `tool?`, `elapsedMs?`, `idleMs?` | **Turn status line** ([proposal 32](../proposals/32-turn-status-line.md)). Sent right after `history` on every attach (so a reattach learns whether a turn is running), on turn start, on each phase change (never per delta), every 5 s while running (heartbeat), and once with `running:false` at turn end (after `result`). Durations are relative, so there's no clock skew. `idleMs` = time since the model/engine last produced anything. Authoritative for the client's `busy` |
| `thinking_delta` | `text` | **Live reasoning summary** ([proposal 36](../proposals/36-thinking-blocks.md)). Streamed while the model thinks; the client grows one collapsed row. Claude engine only; absent when thinking is omitted or `VIBE_SHOW_THINKING=0` |
| `thinking` | `text` | The final summarized thinking block, sent **before** the turn's `assistant` frame and persisted as a `thinking` history row. Replaces the row the deltas built (or stands alone on a late attach). Never sent empty |
| `model` | `model` (string\|null), `canSwitch` (bool) | The session's current model ([proposal 37](../proposals/37-live-model-switch.md)). Sent on attach and after each successful `set_model`. `canSwitch:true` ⇒ the client may offer "Switch model…"; the native engine never sends this frame |
| `effort` | `effort` (string\|null), `levels` (string[]) | The session's reasoning effort and the levels it accepts ([proposal 39](../proposals/39-effort-control.md)). Sent on attach and after each successful `set_effort`. Absent on the native engine |
| `context` | `tokens`, `max`, `percent`, `autoCompactAt` (int\|null), `categories` (`[{name,tokens}]`, window-occupying only, largest first), `memoryFiles` (`[{path,type,tokens}]`, ≤20 — the CLAUDE.md / auto-memory files loaded), `rules` (bool — were the daemon's session rules appended when this session started), `model` | **Context-window usage** ([proposal 40](../proposals/40-context-meter-compact.md)). Sent after every turn and on attach (cached reading immediately, a fresh one when idle). `autoCompactAt` is where the SDK compacts by itself; null when that is off. Claude engine only |
| `compacted` | `text`, `trigger` (`'manual'`\|`'auto'`), `preTokens`, `postTokens` | The SDK compacted the conversation. Also persisted as a `notice` history row (`role:"notice"`, `content` = `text`) so a reattach still shows it |
| `commands` | `commands` (`[{name, description, hint}]`) | Skills and project/plugin commands the session can run as `/name args` ([proposal 41](../proposals/41-slash-commands.md)). Sent at session start (before any message), on attach (cached), and when the SDK reports a change. Claude Code's terminal built-ins (`/config`, `/clear`, …) are withheld. Running one is an ordinary `user` frame whose text starts with `/`. Claude engine only |
| `mcp` | `servers` (`[{name, status, version?, scope?, error?, toolCount, tools:[{name, description, readOnly?, destructive?}]}]`), `truncated` | The session's MCP servers ([proposal 43](../proposals/43-mcp-view.md)), on request and after every `mcp_action`. `status` ∈ `connected\|failed\|needs-auth\|pending\|disabled\|unknown`. **Never contains launch commands, args, env vars or URLs.** Lists are capped (50 servers / 400 tools; `toolCount` is the real number) |
| `user_ack` | `messageId` | The daemon row id of the user turn just accepted (`pushUser`). The client attaches it to the bubble it added locally (FIFO: newest user bubble without an id) so "Rewind files to here" works without a reattach. Claude engine only |
| `rewound` | `messageId`, `filesChanged` (project-relative paths), `ts` | **File rewind happened** ([ADR 0023](../decisions/0023-checkpoint-rewind.md)). Sent to the attached client after a real `POST /sessions/:id/rewind`, so every open view refreshes its changed-files list. Claude engine only |
| `usage` | `usage` (`{session:{label,pct,resetsAt,severity}, weekly:[…]}`) | **Max-plan meters** (rolling 5-hour session window + weekly per-model limits), fetched from `GET /api/oauth/usage` with the CLI-login OAuth token (`usage.ts`). Sent on attach and after each `result`. **Best-effort + fail-soft** — absent in gateway mode (no Max token) or on any fetch error; the client shows nothing rather than a stale/fake number |
| `title` | `title`, `auto?` (bool) | The session's display title changed server-side (auto-titler, [ADR 0009](../decisions/0009-auto-session-title.md)). Sent on attach when the row has a title, again when the first user turn is heuristically titled, and once more if the LLM refine succeeds. The client renders it over its cached `Session.label`; the same value is what `GET /sessions` returns |
| `error` | `message` | SDK error (e.g. CLI login expired) — surfaced, not a hang |
| `external` | `status` (`busy`/`idle`), `canReply` (bool) | **Mirror mode only** — a CLI on the server owns this session (see Lifecycle). Sent after `history` and on each status change |
| `dialog_closed` | `dialogId` | That question was answered (first answer wins, from any device, or the CLI in Mirror mode) or timed out; drop its card |
| `permission_closed` | `toolUseID` | That approval was answered by another device, timed out or was flushed by auto-allow; drop its card (proposal 58) |
| `user_turn` | `text` | **Mirror mode only** — a user turn from the CLI's transcript. The client doesn't echo its own `user` locally while mirroring; it arrives here |

## Permissions (security.md — highest scrutiny)

`permissionMode: 'default'` + the SDK `canUseTool` callback. **Auto-allow is on
by default**: every tool call is approved immediately (no round-trip, no pause)
and audited as `permission.auto_allow`. The phone's settings toggle ("Auto-allow
tool permissions", default on) syncs the per-session flag via the `auto_allow`
frame on every attach and on change.

With auto-allow **off**, every tool call emits a `permission_request` and
**blocks** until the client answers or it times out. Rules:

- **Deny on timeout** (120 s), attached or not — a phone tapping "allow" is the
  gate that lets a command run on the box. With no client attached the request
  also fires a push, and the phone can answer it over REST
  (`POST /sessions/:id/permission`) inside the same 120 s ([ADR 0013](../decisions/0013-push-notifications.md)).
- Every decision (`auto_allow` / `allow` / `deny` / `timeout`) is written to the
  `events` audit log (`security.md` #5). An `allow`/`deny` carries the
  **`device_id` of the phone that answered**; `auto_allow` and `timeout` carry
  none, because no human made them.
- A `permission_request` pending when the socket drops is **replayed** on the
  next attach (so a roam mid-approval recovers) — see `ClaudeSession.attach`.
- Turning auto-allow **on** resolves any pending `permission_request` as an
  allow (audited), so a mid-approval toggle unblocks the turn.
- Never `bypassPermissions` — the gate stays in place (auditing, AskUserQuestion
  routing); auto-allow only changes the default answer.

### Modes (proposal 25)

Auto-allow is now one of three **session modes**, set with the `mode` frame (or
`POST /sessions {mode}`), persisted in `sessions.mode`, reported by the `mode`
frame:

| Mode | SDK `permissionMode` | Gate | Behavior |
|------|----------------------|------|----------|
| `ask` | `default` | auto-allow off | every tool call round-trips (above) |
| `auto` | `default` | auto-allow on | the daemon default (proposal 18) |
| `plan` | `plan` | auto-allow on (reads) | read-only research; the SDK refuses writes itself |

Switching is live via `Query.setPermissionMode()` (before `start()` it is applied
through `options.permissionMode`). Every change is audited `session.mode`
(`<sessionId>:<mode>`, with the changing device's id).

**ExitPlanMode is never auto-allowed.** It arrives through `canUseTool` with
`{plan, planFilePath}` and is turned into a `user_dialog` with
`dialogKind: 'exit_plan'`, `payload: {plan, planFilePath}` — no timeout, replayed
on attach, pushed when detached (like AskUserQuestion). Answer with
`dialog_response`, `completed: true`, `result`:

- `{approve: true, mode?: 'auto'|'ask'}` → allow; the SDK leaves plan mode, and the
  daemon moves to `mode` (default: the mode before plan). Only if the session is
  still in `plan` — a mode the user chose by hand meanwhile is not overridden.
- `{approve: false, feedback?: string}` → deny with `feedback` as the message; the
  model stays in plan mode and revises.
- `completed: false` / session stop → deny.

Verified against the real SDK: [spikes/M7-spike-plan-mode.md](../spikes/M7-spike-plan-mode.md).

### Diff preview (proposal 02)

For `Edit` / `Write` / `MultiEdit`, `permission_request` carries an optional
`diffPreview` so the human sees the change before approving it:

```jsonc
"diffPreview": { "relPath": "lib/a.dart", "diff": "@@ -1,1 +1,1 @@\n-one\n+two",
                 "adds": 1, "dels": 1, "truncated": false }
```

Absent for every other tool; an older client ignores it. Rules:

- **Render == execution.** The daemon builds the preview
  (`previewForTool`, diff-preview.ts) from the **same `input` object** the gate
  later resolves as `updatedInput`. Never rebuild a diff client-side from a
  partial `input` — `Edit` sends `old_string` only, so a reconstruction can drift
  and the user would approve something other than what runs.
- **No silent truncation.** A cut appends a visible `… +N lines truncated` line
  and sets `truncated: true`; `adds`/`dels` count the whole edit, not the shown
  slice.
- **Swipe is additive.** The client may map swipe-right/left to allow/deny, but
  it sends the same `{t:'permission', toolUseID, allow}` frame and produces the
  same audit rows. High-risk tools (`Bash`, `Write`) confirm first. There is no
  swipe-specific daemon path.
- Replayed requests keep their preview, so a reattach mid-approval still shows
  the diff.

Security note: with auto-allow on, anything Claude decides to run executes on
the box without a human tap. The compensating controls are the tailnet + bearer
transport boundary, the per-decision audit log, and the toggle itself.

## Auto-title ([ADR 0009](../decisions/0009-auto-session-title.md))

Sessions are named from their **first turn** so the phone never shows a raw
`s_…` id. Two phases, both emitting a `title` frame:

1. **Heuristic**, written synchronously when the first user turn is inserted —
   `"<project dir> · <first prompt, squashed to one line>"`, capped at 60 chars.
2. **LLM refine**, one tool-less single-turn call fired after that turn's
   `result`. Fail-soft: any timeout / bad model / junk output leaves the
   heuristic. It runs in SDK isolation (`settingSources: []`, `tools: []`,
   `maxTurns: 1`) so a project's `CLAUDE.md`, settings and hooks never leak into
   a throwaway summarization, and it can't touch the filesystem.

First turn **only** — the title never moves under the user afterwards. A manual
`PATCH /sessions/:id { title }` clears `sessions.title_auto` and pins the title
for good. `attach()` re-sends the stored title because a create-with-prompt
session ([proposal 15](../proposals/15-initialprompt-atomicity.md)) is primed
before any socket exists.

Env: `VIBE_AUTO_TITLE=0` (off), `VIBE_AUTO_TITLE_LLM=0` (heuristic only),
`VIBE_TITLE_MODEL` (default `claude-haiku-4-5`), `VIBE_TITLE_TIMEOUT_MS` (20 s),
`VIBE_TITLE_MAX_INFLIGHT` (2).

## AskUserQuestion (verified — SDK 0.3.169, 2026-06-18)

**AskUserQuestion is a normal tool — it arrives through `canUseTool`, NOT via
`onUserDialog`.** Confirmed live: the model's call logs a
`permission.allow :: …:AskUserQuestion` event and **never** fires a
`request_user_dialog` control request. The tool's own input schema carries an
`answers` field documented as *"answers collected by the permission component"* —
i.e. the host collects the picks **inside the permission gate** and returns them,
rather than rendering a separate dialog.

> ⚠️ The earlier design here (route AskUserQuestion through `onUserDialog`) was
> wrong for this SDK version and caused the bug it was meant to prevent: the
> phone showed a generic allow/deny card (no questions), the tool ran with no
> answers, parked a few seconds on the CLI deadline, and returned *"The user did
> not answer the questions."* `onUserDialog` is still wired but only fires for
> **other** `dialogKind`s; nothing we render today.

Flow (`ClaudeSession.askUserQuestion`, `src/claude.ts`):

1. `canUseTool('AskUserQuestion', input, …)` fires. `input` carries a
   `questions[]` array (1–4 questions, each 2–4 options `{label, description}`,
   `multiSelect` bool) — the AskUserQuestion tool-input schema verbatim.
2. The daemon mints a `dialogId` and **reuses the `user_dialog` frame** to ship
   the questions to the phone: `{t:'user_dialog', dialogKind:'ask_user_question',
   payload: input, …}`. (Transport reuse only — the phone's existing question UI
   already parses this `payload.questions[]` shape.)
3. The phone renders the chips; the user picks; it replies `dialog_response` with
   `result = { questions, answers }`, where `answers` maps each **question text →
   chosen option label** (multi-select labels comma-joined).
4. The daemon resolves the **`canUseTool`** promise with
   `{behavior:'allow', updatedInput:{ …input, answers }}`. The tool executes with
   the answers pre-filled and reports *"User answered: …"*.

Rules (mirror the permission gate):

- **No timeout** — the question waits indefinitely for the user (a session
  `stop()` resolves it as cancelled). **Cancel = allow with the original input**
  (no `answers`) — the tool then reports "did not answer". With **no client
  attached** it now waits too and fires a push; the phone answers from the
  notification (`POST /sessions/:id/dialog`) or on reattach ([ADR 0013](../decisions/0013-push-notifications.md)). Never `deny`: AskUserQuestion is Q&A, not a command, and a deny would
  surface as a tool error instead of a clean skip.
- **Auto-allow does not apply** — AskUserQuestion always round-trips to the
  phone; auto-answering it would defeat the tool.
- The `user_dialog` frame is **replayed** on reattach (via `pendingDialogs`),
  same as `permission_request`.
- A `user_dialog` the client can't render (no `questions`) is auto-cancelled so
  the session never hangs.

## Attachments (image input)

A `user` turn can carry images (proposal 16, SDK format confirmed by
`vibe-daemon/src/spike-image.ts` — the SDK forwards `{type:'image', source:{type:
'base64', media_type, data}}` blocks in the streaming input). Binary does **not**
ride the JSON event channel; it's uploaded over REST first:

1. Client downscales (≤1568px long edge, ≤5MB) and `POST /sessions/:id/attachments`
   (raw image body) → `{attachmentId, mediaType}` ([session-rest.md](./session-rest.md)).
2. Client sends `{t:'user', text, images:[attachmentId, …]}`.
3. Server reads each blob from SQLite, base64s it, and builds a multimodal user turn —
   `content: [{type:'text',text}, {type:'image', source:{type:'base64', media_type,
   data}}, …]` — pushed into the SDK input stream (`pushUser(text, images[])`,
   `src/claude.ts`). The blob is fetched by id **filtered on this session** — a turn
   can't pull another session's image.
4. `messages` persists the **ref** (attachmentId + mediaType), never the bytes; the
   blob is a SQLite BLOB. `history` replays the ref; the client lazy-fetches the image.

Security (lower risk than the gate — image is data, not a command — but it's a
**client-controlled write**, so security.md applies): media allowlist by magic
bytes (png/jpeg/webp/gif), server-enforced size cap, server-minted random id (no
client path → no traversal), stored as a SQLite BLOB (no filesystem write surface),
and an `events` audit row per upload. Same bearer auth as every route.

## Liveness

WS control-frame ping/pong, same as the terminal (server 15 s heartbeat; client
`pingInterval`). No app-level ping on the byte/event stream.

## Gotchas

- WS close = **detach**, never stop. Stopping is only `DELETE /sessions/:id`.
- The `id` is the **stable** sessions-row id; reuse it across reconnects (a new id
  starts a fresh SDK session and orphans the old one).
- `delta` frames are transient (not persisted); the finalized `assistant` frame is
  what `history` replays. On reattach you get history (no deltas) + live stream.
- Each live claude session is a `claude` subprocess — `stop()` must reap it.
- `AskUserQuestion` **does** fire `canUseTool` (SDK 0.3.169, verified). Don't
  send it a plain allow/deny card — render its `input.questions` and return
  `{behavior:'allow', updatedInput:{…input, answers}}`, or the tool runs with no
  answers and returns "did not answer". See above.
