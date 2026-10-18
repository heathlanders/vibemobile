// Hardened git runner (ADR 0024, security.md #15).
//
// The agent can write `.git/hooks/*` and `.git/config` in any project it works
// in, so any git command the DAEMON runs there would execute whatever the repo
// says (core.fsmonitor, core.sshCommand, credential.helper, diff.external,
// hooks) with the daemon's rights. Every daemon git call goes through here:
//   - execFile with an ARRAY (never a shell string)
//   - `-c` overrides, which beat repo-local config, neutralise the code-exec knobs
//   - env stripped of GIT_* (GIT_DIR, GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF, …)
//   - timeout + output cap
//   - refuse repos whose config defines filter/merge/diff driver commands (ADR 0032 §4):
//     .gitattributes picks the driver NAME, so no fixed `-c` list can blank them all

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

export const GIT_TIMEOUT_MS = 5000;
export const GIT_MAX_BUFFER = 1024 * 1024;

// Prepended to every invocation. `-c` takes precedence over repo config.
export const GIT_HARDEN_ARGS: readonly string[] = [
  "-c", "core.hooksPath=/dev/null",
  "-c", "core.fsmonitor=false",
  "-c", "core.sshCommand=ssh",
  "-c", "credential.helper=",
  "-c", "diff.external=",
  "-c", "protocol.ext.allow=never",
];

export function gitEnv(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(base)) if (!k.toUpperCase().startsWith("GIT_")) env[k] = v;
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_TERMINAL_PROMPT = "0";
  env.GIT_OPTIONAL_LOCKS = "0";
  return env;
}

// Config keys whose value git runs as a command during add/checkout/diff/merge.
// Subsections may contain dots, so match on the first section and the last key.
// `includeIf.onbranch:` is refused too: what it pulls in changes with the checked-out
// branch, so a check on one branch says nothing about the next checkout.
const DRIVER_KEY =
  /^(filter\..+\.(clean|smudge|process)|merge\..+\.driver|diff\..+\.(textconv|command)|includeif\.onbranch:.*)$/i;

export class UnsafeGitConfigError extends Error {
  constructor(readonly key: string) {
    super(`repo_config_unsafe: ${key}`);
  }
}

// Input: `git config -z --list` output (`key\nvalue\0` entries). Returns the first
// refused key, or null.
export function unsafeDriverKey(listZ: string): string | null {
  for (const entry of listZ.split("\0")) {
    const nl = entry.indexOf("\n");
    const key = nl < 0 ? entry : entry.slice(0, nl);
    if (DRIVER_KEY.test(key)) return key;
  }
  return null;
}

export async function gitRun(
  cwd: string,
  argv: string[],
  opts: { timeout?: number; maxBuffer?: number } = {},
): Promise<{ stdout: string; stderr: string }> {
  // `--list` follows include.path, so drivers pulled in from other files show up too.
  // Listing config never runs a driver. Checked on every call, in the cwd the call runs
  // in (includeIf gitdir: differs per worktree); the agent can edit config at any time,
  // so a gap between this check and the real call remains. Submodules have their own
  // config this can't see: callers keep git out of them (--ignore-submodules=all on
  // status, no `add -u` when the index has gitlinks).
  const { stdout: config } = await exec("git", [...GIT_HARDEN_ARGS, "config", "-z", "--list"], {
    cwd,
    env: gitEnv(),
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: GIT_MAX_BUFFER,
  });
  const bad = unsafeDriverKey(config);
  if (bad) throw new UnsafeGitConfigError(bad);
  return exec("git", [...GIT_HARDEN_ARGS, ...argv], {
    cwd,
    env: gitEnv(),
    timeout: opts.timeout ?? GIT_TIMEOUT_MS,
    maxBuffer: opts.maxBuffer ?? GIT_MAX_BUFFER,
  });
}
