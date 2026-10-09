# M8 spike — SDK file checkpointing + rewind

**Question (proposals 27/28):** can the daemon rewind a live Agent SDK session's
file edits to an earlier user message, using uuids it mints itself, including
across a `resume` and inside a git worktree cwd?

**Script:** `vibe-daemon/src/spike-checkpoint.ts [worktree]` — throwaway temp-dir
cwd, SDK 0.3.291, real Claude (a few cents per run). Run 2026-10-07, both modes.

## Results

| # | Question | Result |
|---|----------|--------|
| a | Is a caller-minted `SDKUserMessage.uuid` accepted by `rewindFiles`? | **Yes.** The uuid we put on the queued user message is the one `rewindFiles` takes. The SDK does **not** echo input user messages on the stream (no `replayUserMessages`), so "echo" is not the test — acceptance is. |
| b | `rewindFiles(u, {dryRun:true})` | **Works, no side effects.** Returns `{canRewind, filesChanged:[absolute paths], insertions, deletions}`. `skippedLinks` is absent on dry runs (documented). |
| c | Semantics of `rewindFiles(u)` | **Restores the state from *before* message `u`'s edits** (i.e. undoes `u` and everything after). Rewinding to turn 2's uuid left turn 1's content; rewinding to turn 1's uuid deleted a file turn 1 created. UI wording must be "undo this message's changes and everything after", not "go back to after this message". |
| d | Bash-made edits | **Not tracked.** `echo bash > c.txt` survived both rewinds. UI must say so. |
| e | cwd = a git worktree | **Works** — same results with `.vibe-worktrees/w1` as cwd. |
| f | After a fresh `query({resume})` | **Checkpoints survive.** A pre-resume uuid is still `canRewind:true`, and an edit made after resume rewinds. (Same on-disk session, same CLI config dir.) |
| g | Real rewind result | `{canRewind:true, skippedLinks:0}` — **no file list on a real run**, so the daemon must take `filesChanged` from the dry run it did first. |

## Consequences for the design

- `filesChanged` are **absolute paths**: the daemon must `canonical` +
  `pathInRoots` each before allowing the real call.
- Real runs return no file list: always dry-run first, check, then run for real,
  and report the dry-run list to clients.
- The daemon must persist the minted uuid per user message (`messages.sdk_uuid`)
  since nothing echoes it.
- Not yet proven here: behavior after a **daemon restart that loses the `Query`**
  beyond the fresh-`resume` case above (same process family), and `forkSession`
  dropping checkpoints (documented in the SDK, not exercised).
- `enableFileCheckpointing` is not supported together with `sessionStore` (SDK
  throws); the daemon does not use `sessionStore`.

## Re-run

```
cd vibe-daemon
npx tsx src/spike-checkpoint.ts            # plain temp dir
npx tsx src/spike-checkpoint.ts worktree   # cwd = git worktree
```
