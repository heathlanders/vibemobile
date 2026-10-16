// Project files API (proposal 59, ADR 0030, security.md #33): list, text read/save with sha
// concurrency, atomic writes, binary download/upload, confinement, secrets, .git, caps, audit.

import test from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { createPairingCode } from "./auth.js";
import { _setStatfsForTest } from "./settings.js";
import { contentDisposition } from "./project-files.js";

const BASE = realpathSync(mkdtempSync(join(tmpdir(), "vibe-pf-")));
process.env.VIBE_PROJECT_ROOTS = BASE;
const OUTSIDE = realpathSync(mkdtempSync(join(tmpdir(), "vibe-pf-out-")));
writeFileSync(join(OUTSIDE, "outside.txt"), "OUTSIDE");
const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

let n = 0;
function project() {
  const root = join(BASE, `proj${++n}`);
  mkdirSync(join(root, "src"), { recursive: true });
  mkdirSync(join(root, ".git"));
  writeFileSync(join(root, ".git", "config"), "[core]\n");
  writeFileSync(join(root, "README.md"), "# hello\n");
  writeFileSync(join(root, "src", "main.ts"), "export const x = 1;\n");
  writeFileSync(join(root, ".env"), "KEY=secret");
  writeFileSync(join(root, "id_rsa"), "PRIVATE");
  writeFileSync(join(root, "bin.dat"), Buffer.from([1, 2, 0, 3]));
  symlinkSync(join(OUTSIDE, "outside.txt"), join(root, "escape.txt"));
  symlinkSync(join(root, ".git", "config"), join(root, "gitlink"));
  symlinkSync(join(root, "README.md"), join(root, "readme-link"));
  return root;
}
const leftovers = (dir: string) => readdirSync(dir).filter((f) => /\.vibe-.*\.tmp$/.test(f));

async function setup(root = project()) {
  _setStatfsForTest(() => ({ free: 1e13 }));
  const db = openDb(":memory:");
  const app = await buildApp(db);
  const { token } = (await app.inject({ method: "POST", url: "/pair", payload: { code: createPairingCode(db), device_name: "t" } })).json();
  const auth = { authorization: `Bearer ${token}` };
  db.prepare("INSERT INTO projects (id, path, name, type) VALUES ('p',?,'p','unknown')").run(root);
  db.prepare("INSERT INTO sessions (id, project_id, kind, status, created_at) VALUES ('s','p','terminal','live',?)").run(new Date().toISOString());
  const get = (url: string) => app.inject({ method: "GET", url, headers: auth });
  const putText = (body: object, scope = "/projects/p") => app.inject({ method: "PUT", url: `${scope}/files/text`, headers: auth, payload: body });
  const putRaw = (path: string, body: Buffer, q = "", scope = "/projects/p") =>
    app.inject({ method: "PUT", url: `${scope}/files/raw?path=${encodeURIComponent(path)}${q}`, headers: { ...auth, "content-type": "application/octet-stream" }, payload: body });
  const read = async (path: string, scope = "/projects/p") => (await get(`${scope}/files/text?path=${encodeURIComponent(path)}`)).json();
  return { root, db, app, auth, get, putText, putRaw, read };
}
const enc = encodeURIComponent;

test("contentDisposition: ASCII fallback plus RFC 5987 name, no quotes or CR/LF", () => {
  const h = contentDisposition('we"ird\r\nna;me é.txt');
  assert.match(h, /^attachment; filename="[\x20-\x7e]*"; filename\*=UTF-8''/);
  assert.ok(!/["\r\n]/.test(h.split("filename=\"")[1].split("\"")[0]));
  assert.ok(h.includes("%C3%A9"));
});

test("requires auth; unknown project 404", async () => {
  const { app, get } = await setup();
  assert.equal((await app.inject({ method: "GET", url: "/projects/p/files" })).statusCode, 401);
  assert.equal((await get("/projects/nope/files")).statusCode, 404);
  assert.equal((await get("/sessions/nope/files")).statusCode, 404);
});

test("list: browse shape, .git hidden, both scopes, any session kind", async () => {
  const { get } = await setup();
  for (const scope of ["/projects/p", "/sessions/s"]) {
    const l = (await get(`${scope}/files`)).json();
    const names = l.entries.map((e: any) => e.name);
    assert.ok(names.includes("README.md") && names.includes(".env") && !names.includes(".git"));
    assert.equal(l.entries.find((e: any) => e.name === ".env").readable, false);
    assert.equal((await get(`${scope}/files?path=src`)).json().path, "src");
  }
});

test("text read: content, sha, mtime, size; sha matches bytes", async () => {
  const { read } = await setup();
  const r = await read("README.md");
  assert.equal(r.content, "# hello\n");
  assert.equal(r.sha, sha("# hello\n"));
  assert.equal(r.size, 8);
  assert.ok(!Number.isNaN(Date.parse(r.mtime)));
  assert.equal("truncated" in r, false);
});

test("text read errors: binary 415, dir 400, missing 404, over edit cap 413", async () => {
  const { get, root } = await setup();
  assert.equal((await get("/projects/p/files/text?path=bin.dat")).statusCode, 415);
  assert.equal((await get("/projects/p/files/text?path=src")).statusCode, 400);
  assert.equal((await get("/projects/p/files/text?path=nope.txt")).statusCode, 404);
  assert.equal((await get("/projects/p/files/text")).statusCode, 400);
  process.env.VIBE_MAX_EDIT_BYTES = "10";
  try {
    writeFileSync(join(root, "big.txt"), "x".repeat(11));
    const r = await get("/projects/p/files/text?path=big.txt");
    assert.equal(r.statusCode, 413);
    assert.ok(!("content" in r.json()));
  } finally {
    delete process.env.VIBE_MAX_EDIT_BYTES;
  }
});

test("traversal, absolute, drive letter, symlink escape: refused for read/write/upload/download", async () => {
  const { get, putText, putRaw } = await setup();
  // An absolute path is read as relative to the root (browse.ts behaviour): "/etc/passwd" -> "etc/passwd", absent -> 404.
  for (const p of ["../x", "../../etc/passwd", "src/../../x", "/etc/passwd", "C:/Windows/x", "C:\\x", "escape.txt"]) {
    const ok = [400, 403, ...(p === "/etc/passwd" ? [404] : [])];
    const g = await get(`/projects/p/files/text?path=${enc(p)}`);
    assert.ok(ok.includes(g.statusCode), `${p} read -> ${g.statusCode}`);
    assert.ok(!g.body.includes("OUTSIDE"));
    const d = await get(`/projects/p/files/raw?path=${enc(p)}`);
    assert.ok(ok.includes(d.statusCode), `${p} download -> ${d.statusCode}`);
    const w = await putText({ path: p, content: "pwn", create: true });
    assert.ok(ok.includes(w.statusCode), `${p} create -> ${w.statusCode}`);
    const w2 = await putText({ path: p, content: "pwn", baseSha: sha("x") });
    assert.ok(ok.includes(w2.statusCode), `${p} save -> ${w2.statusCode}`);
    const u = await putRaw(p, Buffer.from("pwn"), "&overwrite=1");
    assert.ok(ok.includes(u.statusCode), `${p} upload -> ${u.statusCode}`);
  }
  assert.equal(readFileSync(join(OUTSIDE, "outside.txt"), "utf8"), "OUTSIDE");
  assert.equal(existsSync(join(OUTSIDE, "x")), false);
});

test("403 parity: outside the project answers the same whether or not the target exists", async () => {
  const { get, putText } = await setup();
  const a = await get("/projects/p/files/text?path=../../etc/passwd");
  const b = await get("/projects/p/files/text?path=../../nonexistent-zzz");
  assert.equal(a.statusCode, b.statusCode);
  assert.equal(a.body, b.body);
  const c = await putText({ path: "../../etc/passwd", content: "x", create: true });
  const d = await putText({ path: "../../nonexistent-zzz", content: "x", create: true });
  assert.equal(c.statusCode, d.statusCode);
  assert.equal(c.body, d.body);
});

test(".git in any spelling or via symlink: refused everywhere", async () => {
  const { get, putText, putRaw, root } = await setup();
  for (const p of [".git/config", ".GIT/config", ".Git/config", "gitlink", ".git"]) {
    assert.equal((await get(`/projects/p/files/text?path=${enc(p)}`)).statusCode, 403, p);
    assert.equal((await get(`/projects/p/files/raw?path=${enc(p)}`)).statusCode, 403, p);
    assert.equal((await putText({ path: p, content: "x", baseSha: sha("") })).statusCode, 403, p);
    assert.equal((await putRaw(p, Buffer.from("x"), "&overwrite=1")).statusCode, 403, p);
  }
  for (const name of [".git", ".GIT", ".Git"]) {
    assert.equal((await putText({ path: name, content: "x", create: true })).statusCode, 403, name);
    assert.equal((await putRaw(`src/${name}`, Buffer.from("x"))).statusCode, 403, name);
  }
  assert.equal(readFileSync(join(root, ".git", "config"), "utf8"), "[core]\n");
});

test("secret names: refused for text read, download, text write, upload, create", async () => {
  const { get, putText, putRaw, root } = await setup();
  for (const p of [".env", "id_rsa"]) {
    assert.equal((await get(`/projects/p/files/text?path=${p}`)).statusCode, 403, p);
    assert.equal((await get(`/projects/p/files/raw?path=${p}`)).statusCode, 403, p);
    assert.equal((await putText({ path: p, content: "x", baseSha: sha("KEY=secret") })).statusCode, 403, p);
    assert.equal((await putRaw(p, Buffer.from("x"), "&overwrite=1")).statusCode, 403, p);
  }
  for (const p of [".env.local", "src/server.pem", "credentials.json", "id_ed25519"]) {
    assert.equal((await putText({ path: p, content: "x", create: true })).statusCode, 403, p);
    assert.equal((await putRaw(p, Buffer.from("x"))).statusCode, 403, p);
    assert.equal(existsSync(join(root, p)), false);
  }
  assert.equal(readFileSync(join(root, ".env"), "utf8"), "KEY=secret");
  assert.deepEqual(leftovers(root), []);
});

test("save: stale sha 409 returns the current sha; fresh sha writes and re-read matches", async () => {
  const { putText, read, root } = await setup();
  const r0 = await read("README.md");
  writeFileSync(join(root, "README.md"), "changed by claude\n");
  const stale = await putText({ path: "README.md", content: "mine", baseSha: r0.sha });
  assert.equal(stale.statusCode, 409);
  assert.equal(stale.json().sha, sha("changed by claude\n"));
  assert.equal(readFileSync(join(root, "README.md"), "utf8"), "changed by claude\n");

  const ok = await putText({ path: "README.md", content: "héllo ✓\n", baseSha: stale.json().sha });
  assert.equal(ok.statusCode, 200);
  const j = ok.json();
  assert.equal(j.path, "README.md");
  assert.equal(j.size, Buffer.byteLength("héllo ✓\n"));
  const r1 = await read("README.md");
  assert.equal(r1.sha, j.sha);
  assert.equal(r1.content, "héllo ✓\n");
  assert.deepEqual(leftovers(root), []);
});

test("save: body validation (exactly one of baseSha / create, string content)", async () => {
  const { putText } = await setup();
  assert.equal((await putText({ path: "README.md", content: "x" })).statusCode, 400);
  assert.equal((await putText({ path: "README.md", content: "x", baseSha: sha("a"), create: true })).statusCode, 400);
  assert.equal((await putText({ path: "README.md", content: 5, baseSha: sha("a") })).statusCode, 400);
  assert.equal((await putText({ path: "README.md", content: "x", baseSha: "nothex" })).statusCode, 400);
  assert.equal((await putText({ content: "x", create: true })).statusCode, 400);
  assert.equal((await putText({ path: "nope.txt", content: "x", baseSha: sha("a") })).statusCode, 404);
});

test("create: new file ok (0644); existing -> 409; missing folder -> 404; bad names refused", async () => {
  const { putText, read, root } = await setup();
  const c = await putText({ path: "src/new.ts", content: "a\n", create: true });
  assert.equal(c.statusCode, 200);
  assert.equal((await read("src/new.ts")).content, "a\n");
  assert.equal(statSync(join(root, "src", "new.ts")).mode & 0o777, 0o644);
  const again = await putText({ path: "src/new.ts", content: "b", create: true });
  assert.equal(again.statusCode, 409);
  assert.equal(readFileSync(join(root, "src", "new.ts"), "utf8"), "a\n");
  assert.equal((await putText({ path: "README.md", content: "b", create: true })).statusCode, 409);
  assert.equal((await putText({ path: "nodir/x.ts", content: "b", create: true })).statusCode, 404);
  assert.equal((await putText({ path: "src/" + "a".repeat(256), content: "b", create: true })).statusCode, 400);
  assert.equal((await putText({ path: "src/a\\b", content: "b", create: true })).statusCode, 400);
  assert.equal((await putText({ path: "src/a\0b", content: "b", create: true })).statusCode, 400);
  // a file is not a folder
  assert.equal((await putText({ path: "README.md/x", content: "b", create: true })).statusCode, 404);
  assert.deepEqual(leftovers(join(root, "src")), []);
});

test("create onto a dangling symlink is refused (it counts as existing)", async () => {
  const { putText, putRaw, root } = await setup();
  symlinkSync(join(root, "missing-target"), join(root, "dangle"));
  assert.equal((await putText({ path: "dangle", content: "x", create: true })).statusCode, 409);
  assert.equal((await putRaw("dangle", Buffer.from("x"), "&overwrite=1")).statusCode, 409);
  assert.equal(existsSync(join(root, "missing-target")), false);
});

test("mode is preserved on save (755 stays 755)", async () => {
  const { putText, read, root } = await setup();
  writeFileSync(join(root, "run.sh"), "#!/bin/sh\n");
  chmodSync(join(root, "run.sh"), 0o755);
  const r = await read("run.sh");
  assert.equal((await putText({ path: "run.sh", content: "#!/bin/sh\necho hi\n", baseSha: r.sha })).statusCode, 200);
  assert.equal(statSync(join(root, "run.sh")).mode & 0o777, 0o755);
});

test("an in-root symlinked file is written through; the link survives", async () => {
  const { putText, read, root } = await setup();
  const r = await read("readme-link");
  assert.equal(r.path, "README.md");
  assert.equal((await putText({ path: "readme-link", content: "via link\n", baseSha: r.sha })).statusCode, 200);
  assert.ok(lstatSync(join(root, "readme-link")).isSymbolicLink());
  assert.equal(readFileSync(join(root, "README.md"), "utf8"), "via link\n");
});

test("text over the edit cap -> 413 and nothing written", async () => {
  const { putText, root } = await setup();
  process.env.VIBE_MAX_EDIT_BYTES = "16";
  try {
    const r = await putText({ path: "README.md", content: "x".repeat(17), baseSha: sha("# hello\n") });
    assert.equal(r.statusCode, 413);
    assert.equal(readFileSync(join(root, "README.md"), "utf8"), "# hello\n");
    assert.equal((await putText({ path: "big.txt", content: "é".repeat(9), create: true })).statusCode, 413); // 18 bytes
    assert.equal(existsSync(join(root, "big.txt")), false);
  } finally {
    delete process.env.VIBE_MAX_EDIT_BYTES;
  }
  assert.deepEqual(leftovers(root), []);
});

test("download: bytes, headers, nosniff; non-regular 400; missing 404", async () => {
  const { get, root } = await setup();
  const res = await get("/projects/p/files/raw?path=bin.dat");
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.rawPayload, Buffer.from([1, 2, 0, 3]));
  assert.equal(res.headers["content-type"], "application/octet-stream");
  assert.equal(res.headers["content-length"], "4");
  assert.equal(res.headers["x-content-type-options"], "nosniff");
  assert.match(String(res.headers["content-disposition"]), /^attachment; filename="bin\.dat"; filename\*=UTF-8''bin\.dat$/);
  assert.equal((await get("/projects/p/files/raw?path=src")).statusCode, 400);
  assert.equal((await get("/projects/p/files/raw?path=nope")).statusCode, 404);
  writeFileSync(join(root, "näme ü.bin"), "x");
  const u = await get(`/projects/p/files/raw?path=${enc("näme ü.bin")}`);
  assert.match(String(u.headers["content-disposition"]), /filename\*=UTF-8''n%C3%A4me%20%C3%BC\.bin/);
});

test("download over cap -> 413", async () => {
  const { get, root } = await setup();
  process.env.VIBE_MAX_DOWNLOAD_BYTES = "3";
  try {
    assert.equal((await get("/projects/p/files/raw?path=bin.dat")).statusCode, 413);
  } finally {
    delete process.env.VIBE_MAX_DOWNLOAD_BYTES;
  }
  assert.deepEqual(leftovers(root), []);
});

test("upload: new file ok, existing 409 without overwrite, 200 with overwrite=1; missing folder 404", async () => {
  const { putRaw, root } = await setup();
  const body = randomBytes(1000);
  const r = await putRaw("src/blob.bin", body);
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { path: "src/blob.bin", sha: sha(body), size: 1000 });
  assert.equal((await putRaw("src/blob.bin", Buffer.from("zz"))).statusCode, 409);
  assert.equal((await putRaw("src/blob.bin", Buffer.from("zz"), "&overwrite=0")).statusCode, 409);
  assert.deepEqual(readFileSync(join(root, "src", "blob.bin")), body);
  assert.equal((await putRaw("src/blob.bin", Buffer.from("zz"), "&overwrite=1")).statusCode, 200);
  assert.equal(readFileSync(join(root, "src", "blob.bin"), "utf8"), "zz");
  assert.equal((await putRaw("nodir/x.bin", body)).statusCode, 404);
  assert.equal((await putRaw("src/x.bin", body, "&overwrite=maybe")).statusCode, 400);
  assert.equal((await putRaw("empty.bin", Buffer.alloc(0))).statusCode, 200);
  assert.equal(statSync(join(root, "empty.bin")).size, 0);
  assert.deepEqual(leftovers(root).concat(leftovers(join(root, "src"))), []);
});

test("upload over cap -> 413, temp deleted, audited; target untouched", async () => {
  const { putRaw, root, db } = await setup();
  process.env.VIBE_MAX_UPLOAD_BYTES = "100";
  try {
    const r = await putRaw("src/big.bin", Buffer.alloc(101, 7));
    assert.equal(r.statusCode, 413);
    assert.equal(existsSync(join(root, "src", "big.bin")), false);
    const over = await putRaw("README.md", Buffer.alloc(500), "&overwrite=1");
    assert.equal(over.statusCode, 413);
    assert.equal(readFileSync(join(root, "README.md"), "utf8"), "# hello\n");
    assert.equal((await putRaw("src/ok.bin", Buffer.alloc(100, 1))).statusCode, 200);
  } finally {
    delete process.env.VIBE_MAX_UPLOAD_BYTES;
  }
  assert.deepEqual(leftovers(join(root, "src")).concat(leftovers(root)), []);
  const rows = db.prepare("SELECT detail FROM events WHERE kind = 'file.upload_reject'").all() as any[];
  assert.equal(rows.length, 2);
  assert.match(rows[0].detail, /^projects:p:\d+:src\/big\.bin$/);
});

test("a streaming overflow with no Content-Length is also cut off and cleaned up", async () => {
  const { app, auth, root } = await setup();
  process.env.VIBE_MAX_UPLOAD_BYTES = "100";
  try {
    const { Readable } = await import("node:stream");
    const stream = Readable.from([Buffer.alloc(60), Buffer.alloc(60)]);
    const r = await app.inject({
      method: "PUT",
      url: "/projects/p/files/raw?path=chunky.bin",
      headers: { ...auth, "content-type": "application/octet-stream", "transfer-encoding": "chunked" },
      payload: stream,
    });
    assert.equal(r.statusCode, 413);
  } finally {
    delete process.env.VIBE_MAX_UPLOAD_BYTES;
  }
  assert.equal(existsSync(join(root, "chunky.bin")), false);
  assert.deepEqual(leftovers(root), []);
});

test("octet-stream parsers: >5 MiB upload works on the new route; attachments still 413 above 5 MiB", async () => {
  const { app, auth, putRaw, root, db } = await setup();
  const big = randomBytes(6 * 1024 * 1024);
  const r = await putRaw("big.bin", big);
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().sha, sha(big));
  assert.equal(statSync(join(root, "big.bin")).size, big.length);
  db.prepare("INSERT INTO sessions (id, project_id, kind, created_at) VALUES ('sc','p','claude',?)").run(new Date().toISOString());
  const att = await app.inject({
    method: "POST",
    url: "/sessions/sc/attachments",
    headers: { ...auth, "content-type": "application/octet-stream" },
    payload: Buffer.alloc(5 * 1024 * 1024 + 1, 0x89),
  });
  assert.equal(att.statusCode, 413);
});

test("binary round trip: random bytes upload -> download equal, sha matches", async () => {
  const { putRaw, get } = await setup();
  const body = randomBytes(300_000);
  const up = await putRaw("rt.bin", body);
  assert.equal(up.json().sha, sha(body));
  const down = await get("/projects/p/files/raw?path=rt.bin");
  assert.deepEqual(down.rawPayload, body);
  assert.equal(sha(down.rawPayload), up.json().sha);
});

test("symlink escape on upload/download of an existing in-root link to outside is refused", async () => {
  const { putRaw, get } = await setup();
  assert.equal((await putRaw("escape.txt", Buffer.from("pwn"), "&overwrite=1")).statusCode, 403);
  assert.equal((await get("/projects/p/files/raw?path=escape.txt")).statusCode, 403);
  assert.equal(readFileSync(join(OUTSIDE, "outside.txt"), "utf8"), "OUTSIDE");
});

test("diskGuard failure -> 507 with its message; nothing written", async () => {
  const { putRaw, root, app } = await setup();
  _setStatfsForTest(() => ({ free: 1 }));
  try {
    const r = await putRaw("low.bin", Buffer.from("x"));
    assert.equal(r.statusCode, 507);
    assert.match(r.json().error, /free/);
    assert.equal(existsSync(join(root, "low.bin")), false);
    assert.deepEqual(leftovers(root), []);
  } finally {
    _setStatfsForTest(null);
  }
  void app;
});

test("scopes: a session with a worktree is rooted at the worktree, not the project", async () => {
  const { db, root, get, putText, read } = await setup();
  const wt = join(BASE, `wt${n}`);
  mkdirSync(wt);
  writeFileSync(join(wt, "only-in-worktree.txt"), "wt\n");
  db.prepare("UPDATE sessions SET worktree_path = ? WHERE id = 's'").run(wt);
  assert.equal((await read("only-in-worktree.txt", "/sessions/s")).content, "wt\n");
  assert.equal((await get("/projects/p/files/text?path=only-in-worktree.txt")).statusCode, 404);
  assert.equal((await get("/sessions/s/files/text?path=README.md")).statusCode, 404);
  assert.equal((await putText({ path: "new.txt", content: "w", create: true }, "/sessions/s")).statusCode, 200);
  assert.equal(existsSync(join(wt, "new.txt")), true);
  assert.equal(existsSync(join(root, "new.txt")), false);
  // out-of-roots worktree -> 403
  db.prepare("UPDATE sessions SET worktree_path = ? WHERE id = 's'").run(OUTSIDE);
  assert.equal((await get("/sessions/s/files")).statusCode, 403);
});

test("audit: file.read / file.write / file.download / file.upload rows with device and scope:id:bytes:path", async () => {
  const { putText, putRaw, get, db } = await setup();
  await putText({ path: "a.txt", content: "abc", create: true });
  await get("/projects/p/files/text?path=a.txt");
  await putRaw("b.bin", Buffer.from("12345"));
  await get("/sessions/s/files/raw?path=b.bin");
  const rows = db.prepare("SELECT kind, detail, device_id FROM events WHERE kind LIKE 'file.%' ORDER BY ts").all() as any[];
  const by = (k: string) => rows.find((r) => r.kind === k);
  assert.equal(by("file.read").detail, "projects:p:3:a.txt");
  assert.equal(by("file.write").detail, "projects:p:3:a.txt");
  assert.equal(by("file.upload").detail, "projects:p:5:b.bin");
  assert.equal(by("file.download").detail, "sessions:s:5:b.bin");
  assert.ok(rows.every((r) => r.device_id));
});

test("concurrent saves with the same base sha: exactly one wins, the other gets 409", async () => {
  const { putText, read, root } = await setup();
  const r = await read("README.md");
  const [a, b] = await Promise.all([
    putText({ path: "README.md", content: "A\n", baseSha: r.sha }),
    putText({ path: "README.md", content: "B\n", baseSha: r.sha }),
  ]);
  assert.deepEqual([a.statusCode, b.statusCode].sort(), [200, 409]);
  assert.deepEqual(leftovers(root), []);
});

test("raw upload with any other content type -> 415, no temp file, no hang", async () => {
  const { app, auth, root } = await setup();
  for (const type of ["image/png", "application/json", "text/plain"]) {
    const r = await app.inject({
      method: "PUT",
      url: "/projects/p/files/raw?path=typed.bin",
      headers: { ...auth, "content-type": type },
      payload: type === "application/json" ? "{}" : "xx",
    });
    assert.equal(r.statusCode, 415, type);
  }
  assert.equal(existsSync(join(root, "typed.bin")), false);
  assert.deepEqual(leftovers(root), []);
});

test("a UTF-8 BOM survives read + unchanged save", async () => {
  const { putText, read, root } = await setup();
  const bytes = Buffer.from([0xef, 0xbb, 0xbf, 0x61, 0x0a]);
  writeFileSync(join(root, "bom.txt"), bytes);
  const r = await read("bom.txt");
  assert.equal((await putText({ path: "bom.txt", content: r.content, baseSha: r.sha })).statusCode, 200);
  assert.deepEqual(readFileSync(join(root, "bom.txt")), bytes);
});

test("fs errors never leak a path; control characters in a new name are refused", async () => {
  const { putText, root } = await setup();
  mkdirSync(join(root, "ro"));
  chmodSync(join(root, "ro"), 0o555);
  try {
    const r = await putText({ path: "ro/new.txt", content: "x", create: true });
    assert.equal(r.statusCode, 500);
    assert.doesNotMatch(r.body, /\//);
  } finally {
    chmodSync(join(root, "ro"), 0o755);
  }
  assert.equal((await putText({ path: "bad\nname.txt", content: "x", create: true })).statusCode, 400);
});
