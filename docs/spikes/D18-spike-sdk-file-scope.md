# D18 spike: which file reads reach `canUseTool`

**Question (security.md #7):** does the Agent SDK call `canUseTool` for a Read
outside the session cwd in `permissionMode: 'default'`? If it approves those
itself, the daemon's Auto-mode file scope would never see them.

**Script:** `vibe-daemon/src/spike-file-scope.ts`. It uses throwaway temp dirs
and real Claude (haiku, about a cent). Re-run with
`cd vibe-daemon && npx tsx src/spike-file-scope.ts`. Run 2026-10-06, SDK 0.3.291.

## Result

`canUseTool calls: [["Read","…/outside/out.txt"]]`: the read inside cwd was
approved by the SDK without asking, and the read outside cwd reached
`canUseTool`.

## Consequences

- The scope check sits in the gate's auto-allow branch (`file-scope.ts`, passed
  in by `claude.ts`). A file tool call reaching the gate with a path outside
  every registered project and `~/.claude` now asks the phone, even in Auto mode.
  It's audited as `permission.out_of_scope` followed by the human
  `permission.allow`/`deny`.
- Paths inside cwd never reach the gate, which is fine: cwd is in scope anyway.
- Plan mode writes its plan to `~/.claude/plans/` without calling `canUseTool`
  (M7 spike). That's in scope regardless.
- Bash is not covered. A shell command can touch any path, and parsing it would
  give false confidence.
