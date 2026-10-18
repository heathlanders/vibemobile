// Driver hardening (ADR 0032 §4, security.md #34). The agent can define filter, merge
// and diff drivers in .git/config and point paths at them from .gitattributes; git
// then runs those commands on add/checkout/diff. `-c` can't blank them (the driver
// NAME is the repo's choice), so gitRun refuses the repo instead. Real temp repos.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gitRun, UnsafeGitConfigError, unsafeDriverKey } from "./git-run.js";
import { gitStatus } from "./git.js";
import { createWorktree, WorktreeError } from "./worktree.js";

const ROOT = mkdtempSync(join(tmpdir(), "vibe-gitrun-"));
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "pipe" });

// A repo with one commit whose every path is routed to driver "x", plus a planted
// script that leaves a marker when git runs it.
function planted(name: string, key: string, valueFor: (script: string) => string) {
  const dir = join(ROOT, name);
  mkdirSync(dir);
  git(dir, "init", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init");
  const marker = join(dir, "PWNED");
  const script = join(dir, "evil.sh");
  writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\ncat\n`, { mode: 0o755 });
  writeFileSync(join(dir, ".git", "info", "attributes"), "* filter=x diff=x merge=x\n");
  git(dir, "config", key, valueFor(script));
  writeFileSync(join(dir, "a.txt"), "two\n");
  return { dir, marker };
}

test("control: a planted clean filter DOES run under plain `git add`", () => {
  const { dir, marker } = planted("control", "filter.x.clean", (s) => s);
  git(dir, "add", "a.txt");
  assert.ok(existsSync(marker), "test premise broken: the plant did not fire, so the next tests prove nothing");
});

test("gitRun refuses `add` in a repo with a planted clean filter, and runs nothing", async () => {
  const { dir, marker } = planted("clean", "filter.x.clean", (s) => s);
  await assert.rejects(gitRun(dir, ["add", "a.txt"]), (e: unknown) => e instanceof UnsafeGitConfigError && e.key === "filter.x.clean");
  assert.equal(existsSync(marker), false);
});

test("gitRun refuses `worktree add` with a planted smudge filter", async () => {
  const { dir, marker } = planted("smudge", "filter.x.smudge", (s) => s);
  await assert.rejects(gitRun(dir, ["worktree", "add", "-b", "w", join(ROOT, "smudge-wt"), "HEAD"]), UnsafeGitConfigError);
  assert.equal(existsSync(marker), false);
});

test("gitRun refuses `diff` with a planted textconv", async () => {
  const { dir, marker } = planted("textconv", "diff.x.textconv", (s) => s);
  await assert.rejects(gitRun(dir, ["diff"]), UnsafeGitConfigError);
  assert.equal(existsSync(marker), false);
});

test("a driver pulled in through include.path is still caught", async () => {
  const dir = join(ROOT, "include");
  mkdirSync(dir);
  git(dir, "init", "-b", "main");
  const extra = join(ROOT, "extra.gitconfig");
  writeFileSync(extra, "[merge \"x\"]\n\tdriver = /bin/false %A\n");
  git(dir, "config", "include.path", extra);
  await assert.rejects(gitRun(dir, ["status"]), (e: unknown) => e instanceof UnsafeGitConfigError && e.key === "merge.x.driver");
});

test("a clean repo still works", async () => {
  const dir = join(ROOT, "clean-repo");
  mkdirSync(dir);
  git(dir, "init", "-b", "main");
  const { stdout } = await gitRun(dir, ["rev-parse", "--is-inside-work-tree"]);
  assert.equal(stdout.trim(), "true");
});

test("gitRun refuses a planted filter.*.process and diff.*.command end to end", async () => {
  for (const key of ["filter.x.process", "diff.x.command"]) {
    const { dir, marker } = planted(key.replace(/\W/g, "-"), key, (s) => s);
    await assert.rejects(gitRun(dir, ["diff"]), (e: unknown) => e instanceof UnsafeGitConfigError && e.key === key);
    assert.equal(existsSync(marker), false, key);
  }
});

// Review finding 1: an includeIf that matches only inside the new worktree.
for (const cond of ["gitdir:**/worktrees/**", "onbranch:vibe/**"]) {
  test(`createWorktree does not run a smudge filter pulled in by includeIf ${cond}`, async () => {
    const dir = join(ROOT, `inc-${cond.replace(/\W/g, "")}`);
    mkdirSync(dir);
    git(dir, "init", "-b", "main");
    writeFileSync(join(dir, "a.txt"), "one\n");
    git(dir, "add", "-A");
    git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init");
    const marker = join(dir, "PWNED");
    const script = join(ROOT, `smudge-${cond.replace(/\W/g, "")}.sh`);
    writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\ncat\n`, { mode: 0o755 });
    const extra = join(ROOT, `drv-${cond.replace(/\W/g, "")}.cfg`);
    writeFileSync(extra, `[filter "x"]\n\tsmudge = ${script}\n`);
    writeFileSync(join(dir, ".git", "info", "attributes"), "* filter=x\n");
    git(dir, "config", `includeIf.${cond}.path`, extra);
    await assert.rejects(
      createWorktree(dir, "s_abcdef123456"),
      (e: unknown) => e instanceof WorktreeError && /^repo_config_unsafe: /.test(e.message),
    );
    assert.equal(existsSync(marker), false);
    // Nothing half-made left behind.
    assert.equal(existsSync(join(dir, ".vibe-worktrees", "s_abcdef123456")), false);
    assert.doesNotMatch(git(dir, "branch", "--list").toString(), /vibe\//);
  });
}

test("createWorktree still checks files out in a clean repo", async () => {
  const dir = join(ROOT, "wt-clean");
  mkdirSync(dir);
  git(dir, "init", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init");
  const wt = await createWorktree(dir, "s_0123456789ab");
  assert.ok(existsSync(join(wt.path, "a.txt")));
  assert.equal((await gitStatus(wt.path)).clean, true);
});

// Review finding 2: a submodule's own config and attributes, invisible to the check.
function submoduleRepo(name: string) {
  const sup = join(ROOT, name);
  const upstream = join(ROOT, `${name}-up`);
  for (const d of [sup, upstream]) {
    mkdirSync(d);
    git(d, "init", "-b", "main");
    writeFileSync(join(d, "f.txt"), "one\n");
    git(d, "add", "-A");
    git(d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init");
  }
  git(sup, "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream, "sub");
  git(sup, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "sub");
  const marker = join(sup, "PWNED");
  const script = join(ROOT, `${name}-clean.sh`);
  writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\ncat\n`, { mode: 0o755 });
  const subGit = join(sup, ".git", "modules", "sub");
  git(join(sup, "sub"), "config", "filter.x.clean", script);
  writeFileSync(join(subGit, "info", "attributes"), "* filter=x\n");
  // Same size, new mtime: git must read the content, which runs the clean filter.
  const f = join(sup, "sub", "f.txt");
  writeFileSync(f, "two\n");
  return { sup, marker };
}

test("control: a submodule's clean filter DOES run under plain `git status`", () => {
  const { sup, marker } = submoduleRepo("sm-control");
  git(sup, "status", "--porcelain");
  assert.ok(existsSync(marker), "test premise broken: the submodule plant did not fire");
});

test("gitStatus does not run a submodule's filter", async () => {
  const { sup, marker } = submoduleRepo("sm-status");
  const st = await gitStatus(sup);
  assert.equal(st.repo, true);
  assert.equal(existsSync(marker), false);
});

test("unsafeDriverKey: flags driver commands and onbranch includes, passes harmless keys", () => {
  const list = (pairs: [string, string][]) => pairs.map(([k, v]) => `${k}\n${v}\0`).join("");
  assert.equal(unsafeDriverKey(list([["user.name", "t"], ["filter.lfs.required", "true"], ["includeif.gitdir:~/w/.path", "/x"]])), null);
  // No git-lfs exception: git-lfs reads its own config (customtransfer), the same hole one level down.
  assert.equal(unsafeDriverKey(list([["filter.lfs.clean", "git-lfs clean -- %f"]])), "filter.lfs.clean");
  assert.equal(unsafeDriverKey(list([["diff.x.command", "evil"]])), "diff.x.command");
  assert.equal(unsafeDriverKey(list([["merge.a.b.driver", "evil"]])), "merge.a.b.driver");
  assert.equal(unsafeDriverKey(list([["includeif.onbranch:main.path", "/x"]])), "includeif.onbranch:main.path");
  // A subsection may contain dots or odd case; the key name itself is lowercased by git.
  assert.equal(unsafeDriverKey(list([["filter.My.Drv.clean", "evil"]])), "filter.My.Drv.clean");
});
