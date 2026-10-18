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
import { readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
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
  // Signing/verification run `gpg.program` during rebase, merge and log (ADR 0032 §4).
  "-c", "gpg.program=false",
  "-c", "gpg.ssh.program=false",
  "-c", "gpg.x509.program=false",
  "-c", "commit.gpgSign=false",
  "-c", "merge.verifySignatures=false",
  "-c", "log.showSignature=false",
  // An editor opened by rebase/merge/commit would run whatever core.editor names.
  "-c", "core.editor=false",
  "-c", "sequence.editor=false",
];

export function gitEnv(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [k, v] of Object.entries(base)) if (!k.toUpperCase().startsWith("GIT_")) env[k] = v;
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_TERMINAL_PROMPT = "0";
  env.GIT_OPTIONAL_LOCKS = "0";
  env.GIT_EDITOR = "false";
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

// ---- layout check (ADR 0032 §3) -------------------------------------------------
// The agent owns its worktree's `.git` file and the shared config, so before the merge
// queue runs git in a checkout it proves the checkout still hangs off the project it
// should: the common dir is the project's `.git`, the git dir is the expected one, the
// toplevel is the cwd itself, and no `core.worktree` / `core.bare=true` redirects it.

export class UnsafeGitLayoutError extends Error {
  constructor(why: string) {
    super(`repo_layout_unsafe: ${why}`);
  }
}

const real = (p: string): string => {
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
};

// `core.bare` is written as `false` by every `git init`, so only a true value is a redirect.
export function unsafeLayoutKey(listZ: string): string | null {
  for (const entry of listZ.split("\0")) {
    const nl = entry.indexOf("\n");
    const key = (nl < 0 ? entry : entry.slice(0, nl)).toLowerCase();
    const value = nl < 0 ? "" : entry.slice(nl + 1).trim().toLowerCase();
    if (key === "core.worktree") return key;
    if (key === "core.bare" && !["false", "no", "off", "0"].includes(value)) return key;
  }
  return null;
}

// kind "main": the project checkout itself. kind "worktree": a linked worktree of it.
export async function assertGitLayout(cwd: string, projectPath: string, kind: "main" | "worktree"): Promise<void> {
  const commonWant = real(resolve(projectPath, ".git"));
  const out = (await gitRun(cwd, ["rev-parse", "--git-common-dir", "--absolute-git-dir", "--show-toplevel"])).stdout
    .split("\n")
    .filter(Boolean);
  if (out.length !== 3) throw new UnsafeGitLayoutError("unexpected rev-parse output");
  const common = real(resolve(cwd, out[0]));
  const gitDir = real(out[1]);
  const top = real(out[2]);
  if (common !== commonWant) throw new UnsafeGitLayoutError("git-common-dir");
  if (kind === "main" ? gitDir !== commonWant : dirname(gitDir) !== real(resolve(commonWant, "worktrees"))) {
    throw new UnsafeGitLayoutError("git-dir");
  }
  if (top !== real(cwd)) throw new UnsafeGitLayoutError("toplevel");
  // A `.git` file may point at ANOTHER worktree's git dir of the same project; that dir
  // records which checkout owns it (`gitdir` file), and it must be this one.
  if (kind === "worktree") {
    let owner = "";
    try {
      owner = readFileSync(resolve(gitDir, "gitdir"), "utf8").trim();
    } catch {
      /* unreadable = mismatch */
    }
    if (real(dirname(owner)) !== top || owner.split("/").pop() !== ".git") throw new UnsafeGitLayoutError("worktree owner");
  }
  const bad = unsafeLayoutKey((await gitRun(cwd, ["config", "-z", "--list"])).stdout);
  if (bad) throw new UnsafeGitLayoutError(bad);
}
