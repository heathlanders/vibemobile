// Read-only file browser (proposal 46): confinement, secrets, .git, binaries, caps.

import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { MAX_ENTRIES, MAX_READ_BYTES, listDir, looksSecret, readText, resolveInside } from "./browse.js";

const BASE = realpathSync(mkdtempSync(join(tmpdir(), "vibe-browse-")));
process.env.VIBE_PROJECT_ROOTS = BASE;
const OUTSIDE = realpathSync(mkdtempSync(join(tmpdir(), "vibe-browse-out-")));
writeFileSync(join(OUTSIDE, "outside-secret.txt"), "TOP-SECRET-OUTSIDE");
mkdirSync(join(OUTSIDE, "dir"));
writeFileSync(join(OUTSIDE, "dir", "inner.txt"), "inner");

let n = 0;
function project() {
  const root = join(BASE, `proj${++n}`);
  mkdirSync(join(root, "src", "deep"), { recursive: true });
  mkdirSync(join(root, ".git"));
  writeFileSync(join(root, ".git", "config"), "[remote]\n url = https://user:TOKEN123@github.com/o/r.git\n");
  writeFileSync(join(root, "README.md"), "# hello\nline two\n");
  writeFileSync(join(root, "src", "main.ts"), "export const x = 1;\n");
  writeFileSync(join(root, "src", "deep", "d.txt"), "deep");
  writeFileSync(join(root, ".env"), "API_KEY=sk-live-SECRET");
  writeFileSync(join(root, "id_rsa"), "-----BEGIN PRIVATE KEY-----");
  writeFileSync(join(root, "image.bin"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0, 1, 2]));
  return root;
}
const names = (l: any) => l.entries.map((e: any) => e.name);

// ---- pure ------------------------------------------------------------------------------------

test("looksSecret: git-write's list plus token-bearing config files; plain code is fine", () => {
  for (const s of [".env", ".env.local", "a/b/.env.prod", "k.pem", "x.key", "id_rsa", "id_ed25519.pub", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "keystore.jks", "credentials.json", "secrets.yml", "service-account-prod.json", "client_secret_123.json", "terraform.tfstate", "prod.tfvars"]) {
    assert.equal(looksSecret(s), true, s);
  }
  for (const s of ["README.md", "environment.ts", "src/keyboard.dart", "secrets-manager.ts", "monkey.txt", "package.json", "credentials-form.tsx"]) assert.equal(looksSecret(s), false, s);
});

// ---- listing ---------------------------------------------------------------------------------

test("listDir: dirs first then files, case-insensitive; .git is invisible; secrets listed but not readable", () => {
  const root = project();
  const l = listDir(root, "") as any;
  assert.deepEqual(names(l), ["src", ".env", "id_rsa", "image.bin", "README.md"]);
  assert.ok(!names(l).includes(".git"));
  const byName = Object.fromEntries(l.entries.map((e: any) => [e.name, e]));
  assert.equal(byName[".env"].readable, false);
  assert.equal(byName["id_rsa"].readable, false);
  assert.equal(byName["README.md"].readable, true);
  assert.equal(byName["README.md"].size, 17);
  assert.equal(byName["src"].type, "dir");
  assert.equal(l.path, "");
  const sub = listDir(root, "src") as any;
  assert.deepEqual([sub.path, names(sub)], ["src", ["deep", "main.ts"]]);
  assert.equal((listDir(root, "/src/") as any).path, "src", "leading/trailing slashes are tolerated");
});

test("listDir: a symlink that stays inside is followed; one that escapes is an inert 'link'", () => {
  const root = project();
  symlinkSync(join(root, "src"), join(root, "alias"));
  symlinkSync(OUTSIDE, join(root, "escape-dir"));
  symlinkSync(join(OUTSIDE, "outside-secret.txt"), join(root, "escape-file"));
  symlinkSync(join(root, "nope"), join(root, "dangling"));
  symlinkSync(join(root, ".git"), join(root, "gitlink"));
  const by = Object.fromEntries((listDir(root, "") as any).entries.map((e: any) => [e.name, e]));
  assert.equal(by.alias.type, "dir");
  for (const k of ["escape-dir", "escape-file", "dangling", "gitlink"]) assert.deepEqual([by[k].type, by[k].readable], ["link", false], k);
});

test("listDir caps at MAX_ENTRIES and says so", () => {
  const root = project();
  mkdirSync(join(root, "many"));
  for (let i = 0; i < MAX_ENTRIES + 25; i++) writeFileSync(join(root, "many", `f${String(i).padStart(4, "0")}.txt`), "x");
  const l = listDir(root, "many") as any;
  assert.equal(l.entries.length, MAX_ENTRIES);
  assert.equal(l.truncated, true);
});

test("listDir errors: a file is 400, missing is 404", () => {
  const root = project();
  assert.deepEqual(listDir(root, "README.md"), { status: 400, error: "not a directory" });
  assert.equal((listDir(root, "nope") as any).status, 404);
});

// ---- confinement -------------------------------------------------------------------------------

test("traversal and escapes are refused: .., absolute-looking, symlinked dir/file, drive letter, NUL, over-long, wrong type", () => {
  const root = project();
  symlinkSync(OUTSIDE, join(root, "esc"));
  symlinkSync(join(OUTSIDE, "outside-secret.txt"), join(root, "esc.txt"));
  for (const [rel, status] of [
    ["../../etc", 403], ["src/../../..", 403], ["esc", 403], ["esc/dir", 403], ["esc.txt", 403],
    ["C:\\Windows", 400], ["a\0b", 400], ["x".repeat(1001), 400],
  ] as const) {
    const r = resolveInside(root, rel) as any;
    assert.equal(r.status, status, JSON.stringify(rel).slice(0, 40));
  }
  assert.equal((resolveInside(root, 5 as any) as any).status, 400);
  // an absolute path is NOT interpreted as absolute: it is read relative to the root
  assert.equal((resolveInside(root, "/etc/passwd") as any).status, 404);
  assert.equal((resolveInside(root, `/${OUTSIDE}/outside-secret.txt`) as any).status, 404);
  // a harmless dot-dot that stays inside is fine
  assert.equal((resolveInside(root, "src/deep/../main.ts") as any).rel, "src/main.ts");
});

test(".git is unreachable by any spelling, including through a symlink", () => {
  const root = project();
  symlinkSync(join(root, ".git"), join(root, "g"));
  for (const rel of [".git", ".git/config", ".GIT/config", "src/../.git/config", "g", "g/config"]) {
    const r = readText(root, rel) as any;
    assert.ok(r.status === 403 || r.status === 404, `${rel} -> ${JSON.stringify(r).slice(0, 80)}`);
    assert.ok(!("content" in r), `${rel} must not return content`);
  }
  assert.equal((listDir(root, ".git") as any).status, 403);
});

// ---- reading ---------------------------------------------------------------------------------

test("readText returns text with its real size", () => {
  const root = project();
  const r = readText(root, "README.md") as any;
  assert.deepEqual([r.path, r.size, r.truncated, r.content], ["README.md", 17, false, "# hello\nline two\n"]);
  assert.equal((readText(root, "src/main.ts") as any).content, "export const x = 1;\n");
});

test("secrets are refused (403) and their content never appears; binaries are 415; missing 404; directory 400; empty path 400", () => {
  const root = project();
  for (const f of [".env", "id_rsa"]) {
    const r = readText(root, f) as any;
    assert.equal(r.status, 403, f);
    assert.ok(!JSON.stringify(r).includes("SECRET") && !JSON.stringify(r).includes("PRIVATE"));
  }
  assert.equal((readText(root, "image.bin") as any).status, 415);
  assert.equal((readText(root, "nope.txt") as any).status, 404);
  assert.equal((readText(root, "src") as any).status, 400);
  assert.equal((readText(root, "") as any).status, 400);
  assert.equal((readText(root, undefined) as any).status, 400);
});

test("a symlink to a secret INSIDE the root is judged by its real name too", () => {
  const root = project();
  symlinkSync(join(root, ".env"), join(root, "innocent.txt"));
  assert.equal((readText(root, "innocent.txt") as any).status, 403);
  const by = Object.fromEntries((listDir(root, "") as any).entries.map((e: any) => [e.name, e]));
  assert.equal(by["innocent.txt"].type, "file");
});

test("big files are cut at the cap and flagged", () => {
  const root = project();
  writeFileSync(join(root, "big.txt"), "a".repeat(MAX_READ_BYTES + 5000));
  const r = readText(root, "big.txt") as any;
  assert.equal(r.truncated, true);
  assert.equal(r.size, MAX_READ_BYTES + 5000);
  assert.equal(Buffer.byteLength(r.content), MAX_READ_BYTES);
});

test("a NUL beyond the sniffed head does not make a text file 'binary'; one inside it does", () => {
  const root = project();
  writeFileSync(join(root, "late.txt"), "a".repeat(9000) + "\0tail");
  assert.ok("content" in (readText(root, "late.txt") as object), "NUL past the first 8 KiB: still treated as text");
  writeFileSync(join(root, "early.txt"), "ab\0cd");
  assert.equal((readText(root, "early.txt") as any).status, 415);
});

test("no existence oracle: a path that escapes the project is refused identically whether or not it exists", () => {
  const root = project();
  symlinkSync(OUTSIDE, join(root, "esc"));
  const same = (a: string, b: string) => assert.deepEqual(resolveInside(root, a), resolveInside(root, b), `${a} vs ${b}`);
  same("../../../../../../etc/passwd", "../../../../../../definitely/not/a/real/path");     // lexical escape
  same("esc/outside-secret.txt", "esc/no-such-file-here");                                  // through a symlink that leaves
  same("esc/dir/inner.txt", "esc/dir/missing.txt");
  assert.equal((resolveInside(root, "esc/outside-secret.txt") as any).status, 403);
  assert.equal((resolveInside(root, "src/not-there.ts") as any).status, 404, "inside the project, genuinely missing");
});

// ---- routes ------------------------------------------------------------------------------------

async function setup() {
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  const root = project();
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?,'p','unknown')").run(root);
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','claude','live',?)").run(new Date().toISOString());
  const get = (url: string, headers: Record<string, string> = auth) => app.inject({ method: "GET", url, headers });
  return { db, root, get };
}

test("routes: listing and reading work; a read is audited; errors carry the right status and no content", async () => {
  const { get, db } = await setup();
  const l = (await get("/sessions/s/browse")).json();
  assert.deepEqual(names(l), ["src", ".env", "id_rsa", "image.bin", "README.md"]);
  assert.deepEqual(names((await get("/sessions/s/browse?path=src")).json()), ["deep", "main.ts"]);
  const f = await get("/sessions/s/browse/file?path=README.md");
  assert.equal(f.statusCode, 200);
  assert.equal(f.json().content, "# hello\nline two\n");
  assert.deepEqual((db.prepare("SELECT kind, detail FROM events WHERE kind='file.browse'").get() as any), { kind: "file.browse", detail: "s:README.md:17" });
  for (const [url, status] of [
    ["/sessions/s/browse/file?path=.env", 403], ["/sessions/s/browse/file?path=image.bin", 415], ["/sessions/s/browse/file?path=../../etc/passwd", 403],
    ["/sessions/s/browse/file?path=.git/config", 403], ["/sessions/s/browse/file", 400], ["/sessions/s/browse?path=nope", 404], ["/sessions/nope/browse", 404],
  ] as const) {
    const r = await get(url);
    assert.equal(r.statusCode, status, url);
    assert.ok(!/SECRET|TOKEN123|BEGIN PRIVATE/.test(r.body), `${url} leaked`);
  }
  assert.equal((db.prepare("SELECT COUNT(*) n FROM events WHERE kind='file.browse'").get() as { n: number }).n, 1, "refused reads are not logged as reads");
});

test("routes: a worktree session is rooted at its OWN checkout; a project outside the roots is 403; no token is 401", async () => {
  const { get, db, root } = await setup();
  const wt = join(root, ".vibe-worktrees", "s_abc");
  mkdirSync(wt, { recursive: true });
  writeFileSync(join(wt, "only-in-worktree.txt"), "wt");
  db.prepare("UPDATE sessions SET worktree_path = ? WHERE id = 's'").run(wt);
  assert.deepEqual(names((await get("/sessions/s/browse")).json()), ["only-in-worktree.txt"]);
  assert.equal((await get("/sessions/s/browse/file?path=../README.md")).statusCode, 403, "the parent checkout is outside this session's root");
  db.prepare("UPDATE sessions SET worktree_path = NULL WHERE id = 's'").run();
  db.prepare("UPDATE projects SET path = '/etc' WHERE id = 'p'").run();
  assert.equal((await get("/sessions/s/browse")).statusCode, 403);
  assert.equal((await get("/sessions/s/browse", {})).statusCode, 401);
});
