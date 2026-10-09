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

export async function gitRun(
  cwd: string,
  argv: string[],
  opts: { timeout?: number; maxBuffer?: number } = {},
): Promise<{ stdout: string; stderr: string }> {
  return exec("git", [...GIT_HARDEN_ARGS, ...argv], {
    cwd,
    env: gitEnv(),
    timeout: opts.timeout ?? GIT_TIMEOUT_MS,
    maxBuffer: opts.maxBuffer ?? GIT_MAX_BUFFER,
  });
}
