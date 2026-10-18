// Driver hardening (ADR 0032 §4, security.md #34). The agent can define filter, merge
// and diff drivers in .git/config and point paths at them from .gitattributes; git
// then runs those commands on add/checkout/diff. `-c` can't blank them (the driver
// NAME is the repo's choice), so gitRun refuses the repo instead. Real temp repos.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assertGitLayout, gitRun, UnsafeGitConfigError, UnsafeGitLayoutError, unsafeDriverKey, unsafeLayoutKey } from "./git-run.js";
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

// ---- signing / editor knobs (ADR 0032 §4, added with the merge queue) -----------------

const ID = ["-c", "user.name=t", "-c", "user.email=t@t"];

// main has moved on since `feat` forked, so rebasing `feat` re-creates its commit.
function divergent(name: string) {
  const dir = join(ROOT, name);
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, ...ID, "commit", "-qm", "init");
  git(dir, "checkout", "-qb", "feat");
  writeFileSync(join(dir, "f.txt"), "feat\n");
  git(dir, "add", "-A");
  git(dir, ...ID, "commit", "-qm", "feat");
  git(dir, "checkout", "-q", "main");
  writeFileSync(join(dir, "m.txt"), "main\n");
  git(dir, "add", "-A");
  git(dir, ...ID, "commit", "-qm", "main");
  const marker = join(dir, "PWNED");
  const script = join(dir, "evil.sh");
  writeFileSync(script, `#!/bin/sh\ntouch "${marker}"\nexit 1\n`, { mode: 0o755 });
  return { dir, marker, script };
}

test("control: commit.gpgSign + gpg.program DOES run during a plain `git rebase`", () => {
  const { dir, marker, script } = divergent("gpg-control");
  git(dir, "config", "commit.gpgSign", "true");
  git(dir, "config", "gpg.program", script);
  try {
    git(dir, ...ID, "rebase", "main", "feat");
  } catch {
    /* the script exits 1, so the rebase fails: only the marker matters */
  }
  assert.ok(existsSync(marker), "test premise broken: the signing plant did not fire");
});

test("gitRun rebase does not run a planted gpg.program", async () => {
  const { dir, marker, script } = divergent("gpg-run");
  git(dir, "config", "commit.gpgSign", "true");
  git(dir, "config", "gpg.program", script);
  await gitRun(dir, [...ID, "rebase", "main", "feat"], { timeout: 30_000 });
  assert.equal(existsSync(marker), false);
});

// A commit carrying a `gpgsig` header, written straight into the object store.
function signedCommit(dir: string): string {
  const tree = git(dir, "rev-parse", "HEAD^{tree}").toString().trim();
  const body = `tree ${tree}\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nsigned\n`;
  const file = join(ROOT, `commit-${Math.random().toString(36).slice(2)}.txt`);
  writeFileSync(file, body);
  return git(dir, "hash-object", "-t", "commit", "-w", file).toString().trim();
}

test("control: log.showSignature + gpg.program DOES run under plain `git log`", () => {
  const { dir, marker, script } = divergent("showsig-control");
  const sha = signedCommit(dir);
  git(dir, "config", "log.showSignature", "true");
  git(dir, "config", "gpg.program", script);
  git(dir, "log", "-1", sha);
  assert.ok(existsSync(marker), "test premise broken: the showSignature plant did not fire");
});

test("gitRun log does not run a planted gpg.program", async () => {
  const { dir, marker, script } = divergent("showsig-run");
  const sha = signedCommit(dir);
  git(dir, "config", "log.showSignature", "true");
  git(dir, "config", "gpg.program", script);
  await gitRun(dir, ["log", "-1", sha]);
  assert.equal(existsSync(marker), false);
});

test("gitRun does not open a planted editor", async () => {
  const { dir, marker, script } = divergent("editor");
  git(dir, "config", "core.editor", script);
  git(dir, "config", "sequence.editor", script);
  await gitRun(dir, [...ID, "rebase", "main", "feat"], { timeout: 30_000 });
  await gitRun(dir, ["checkout", "-q", "main"]);
  assert.equal(existsSync(marker), false);
});

// ---- layout check (ADR 0032 §3) ---------------------------------------------------

test("assertGitLayout accepts a project and its linked worktree, refuses redirects", async () => {
  const dir = join(ROOT, "layout");
  mkdirSync(dir);
  git(dir, "init", "-q", "-b", "main");
  writeFileSync(join(dir, "a.txt"), "one\n");
  git(dir, "add", "-A");
  git(dir, ...ID, "commit", "-qm", "init");
  await assertGitLayout(dir, dir, "main");
  const wt = join(ROOT, "layout-wt");
  git(dir, "worktree", "add", "-q", "--detach", wt);
  await assertGitLayout(wt, dir, "worktree");
  // The worktree is not the main checkout, and vice versa.
  await assert.rejects(assertGitLayout(wt, dir, "main"), UnsafeGitLayoutError);
  await assert.rejects(assertGitLayout(dir, dir, "worktree"), UnsafeGitLayoutError);

  // Another repo's worktree does not pass for this project.
  const other = join(ROOT, "layout-other");
  mkdirSync(other);
  git(other, "init", "-q", "-b", "main");
  await assert.rejects(assertGitLayout(other, dir, "main"), UnsafeGitLayoutError);

  // A `.git` file redirected at another repo's worktree gitdir.
  const evil = join(ROOT, "layout-evil");
  mkdirSync(evil);
  writeFileSync(join(evil, ".git"), `gitdir: ${join(realpathSync(dir), ".git", "worktrees", "layout-wt")}\n`);
  await assert.rejects(assertGitLayout(evil, dir, "worktree"), UnsafeGitLayoutError);

  git(dir, "config", "core.worktree", realpathSync(dir)); // same place: only the key itself gives it away
  await assert.rejects(assertGitLayout(dir, dir, "main"), (e: unknown) => e instanceof UnsafeGitLayoutError && /core\.worktree/.test(e.message));
  git(dir, "config", "--unset", "core.worktree");
  rmSync(wt, { recursive: true, force: true });
});

test("unsafeLayoutKey: core.bare=false is normal, true and core.worktree are not", () => {
  const list = (pairs: [string, string][]) => pairs.map(([k, v]) => `${k}\n${v}\0`).join("");
  assert.equal(unsafeLayoutKey(list([["core.bare", "false"], ["user.name", "t"]])), null);
  assert.equal(unsafeLayoutKey(list([["core.bare", "true"]])), "core.bare");
  assert.equal(unsafeLayoutKey(list([["core.worktree", "/x"]])), "core.worktree");
});
