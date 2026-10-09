// Read-only file browser for a session's checkout (proposal 46).
//
//   GET /sessions/:id/browse?path=<dir, relative to the checkout>   -> directory listing
//   GET /sessions/:id/browse/file?path=<file, relative>             -> text content
//
// This is a new READ surface over project files, so it is deliberately narrow:
//   - ROOT-CONFINED by realpath: the target is resolved (symlinks followed) and must sit inside the
//     session's checkout (its worktree, if it has one). `..`, absolute paths and symlinks that
//     escape are refused; an escaping symlink is listed as a plain link and is not navigable.
//   - SECRETS are listed (so the tree looks honest) but never readable: .env*, keys, certificates,
//     credential files. The same deny-list family as git staging (git-write.ts), plus a few more.
//   - `.git` is invisible and unreadable (remote URLs with tokens, hooks, config the agent can edit).
//   - TEXT ONLY, capped (256 KiB), NUL-sniffed: binaries are `415`, never streamed to the phone.
//   - No writes of any kind. Rate-limited, and every file read is audited.

import { lstatSync, openSync, readSync, closeSync, readdirSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, resolve, sep } from "node:path";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent, type Device } from "./auth.js";
import { isSensitivePath } from "./git-write.js";
import { pathInRoots } from "./paths.js";

export const MAX_READ_BYTES = 256 * 1024;
export const MAX_ENTRIES = 500;
const SNIFF_BYTES = 8192;

// On top of git-write's list (.env*, *.pem/key/p12/pfx, id_*, .netrc): files that routinely hold tokens.
const EXTRA_SECRET: RegExp[] = [
  /^\.npmrc$/i, /^\.pypirc$/i, /^\.git-credentials$/i, /^\.dockercfg$/i, /^\.htpasswd$/i,
  /\.(keystore|jks|asc|gpg|kdbx|p8)$/i, /^credentials(\.json)?$/i, /^secrets?\.(json|ya?ml|toml|env)$/i,
  /^service[-_]account.*\.json$/i, /^client_secret.*\.json$/i, /^terraform\.tfstate(\.backup)?$/i, /\.tfvars$/i,
];
export const looksSecret = (name: string): boolean => isSensitivePath(name) || EXTRA_SECRET.some((re) => re.test(basename(name)));

export type Entry = { name: string; type: "dir" | "file" | "link"; size?: number; readable: boolean };
export type Listing = { path: string; entries: Entry[]; truncated: boolean };
export type FileRead = { path: string; size: number; truncated: boolean; content: string };
export type BrowseError = { status: number; error: string };

const bad = (status: number, error: string): BrowseError => ({ status, error });
const inside = (p: string, root: string) => p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);

/** Resolve a client-supplied relative path inside `root`, following symlinks, or explain why not. */
export function resolveInside(root: string, rel: unknown): { real: string; rel: string; root: string } | BrowseError {
  if (rel !== undefined && typeof rel !== "string") return bad(400, "path must be text");
  const r = (rel ?? "").replace(/^\/+|\/+$/g, "");
  if (r.includes("\0") || r.length > 1000) return bad(400, "bad path");
  if (/^[A-Za-z]:/.test(r)) return bad(400, "bad path"); // a drive-letter path is never meant here
  if (r.split("/").some((seg) => seg.toLowerCase() === ".git")) return bad(403, "not available");
  let realRoot: string;
  try {
    realRoot = realpathSync(root);
  } catch {
    return bad(404, "checkout not found");
  }
  const abs = resolve(realRoot, r);
  // 1. Lexical check FIRST, before the filesystem is touched: "../.." is refused the same way
  //    whether or not the target exists (no existence oracle for files outside the project).
  if (!inside(abs, realRoot)) return bad(403, "outside the project");
  // 2. Follow symlinks. For a path that doesn't exist, judge its nearest EXISTING ancestor, so a
  //    symlink pointing out of the project can't be used to probe what exists beyond it either.
  let probe = abs;
  let real: string | null = null;
  for (;;) {
    try {
      real = realpathSync(probe);
      break;
    } catch {
      const up = dirname(probe);
      if (up === probe) return bad(404, "not found");
      probe = up;
    }
  }
  if (!inside(real, realRoot)) return bad(403, "outside the project");
  if (probe !== abs) return bad(404, "not found"); // inside the project, just not there
  // The RESOLVED path must not pass through .git either (a symlink could point into it).
  if (real.slice(realRoot.length).split(sep).some((seg) => seg.toLowerCase() === ".git")) return bad(403, "not available");
  return { real, rel: real === realRoot ? "" : real.slice(realRoot.length + 1).split(sep).join("/"), root: realRoot };
}

export function listDir(root: string, rel: unknown): Listing | BrowseError {
  const t = resolveInside(root, rel);
  if ("status" in t) return t;
  let st;
  try {
    st = statSync(t.real);
  } catch {
    return bad(404, "not found");
  }
  if (!st.isDirectory()) return bad(400, "not a directory");
  let names: string[];
  try {
    names = readdirSync(t.real);
  } catch {
    return bad(403, "cannot read this folder");
  }
  const entries: Entry[] = [];
  let truncated = false;
  for (const name of names) {
    if (name.toLowerCase() === ".git") continue; // invisible
    if (entries.length >= MAX_ENTRIES) {
      truncated = true;
      break;
    }
    const abs = resolve(t.real, name);
    try {
      const l = lstatSync(abs);
      if (l.isSymbolicLink()) {
        // Follow it only if it stays inside the root; otherwise it is an inert "link".
        let target: string | null = null;
        try {
          target = realpathSync(abs);
        } catch {
          /* dangling */
        }
        if (target && inside(target, t.root) && !target.slice(t.root.length).split(sep).some((s) => s.toLowerCase() === ".git")) {
          const s = statSync(target);
          entries.push(s.isDirectory() ? { name, type: "dir", readable: true } : { name, type: "file", size: s.size, readable: s.isFile() && !looksSecret(name) });
        } else {
          entries.push({ name, type: "link", readable: false });
        }
      } else if (l.isDirectory()) {
        entries.push({ name, type: "dir", readable: true });
      } else if (l.isFile()) {
        entries.push({ name, type: "file", size: l.size, readable: !looksSecret(name) });
      } // sockets, fifos, devices: not listed
    } catch {
      /* vanished while listing */
    }
  }
  entries.sort((a, b) => (a.type === "dir" ? 0 : 1) - (b.type === "dir" ? 0 : 1) || a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  return { path: t.rel, entries, truncated };
}

export function readText(root: string, rel: unknown): FileRead | BrowseError {
  if (typeof rel !== "string" || !rel.trim()) return bad(400, "path required");
  const t = resolveInside(root, rel);
  if ("status" in t) return t;
  if (looksSecret(t.real)) return bad(403, "this file looks like a secret and is not shown");
  let st;
  try {
    st = statSync(t.real);
  } catch {
    return bad(404, "not found");
  }
  if (!st.isFile()) return bad(400, "not a file");
  const fd = openSync(t.real, "r");
  try {
    const want = Math.min(st.size, MAX_READ_BYTES);
    const buf = Buffer.alloc(want);
    const n = readSync(fd, buf, 0, want, 0);
    const head = buf.subarray(0, Math.min(n, SNIFF_BYTES));
    if (head.includes(0)) return bad(415, "binary file");
    return { path: t.rel, size: st.size, truncated: st.size > MAX_READ_BYTES, content: buf.subarray(0, n).toString("utf8") };
  } finally {
    closeSync(fd);
  }
}

export function registerBrowseRoutes(app: FastifyInstance, db: DB): void {
  const limit = { config: { rateLimit: { max: 90, timeWindow: "1 minute" } } };
  const rootOf = (id: string): { root: string } | BrowseError => {
    const row = db
      .prepare("SELECT COALESCE(s.worktree_path, p.path) AS root FROM sessions s JOIN projects p ON p.id = s.project_id WHERE s.id = ?")
      .get(id) as { root: string } | undefined;
    if (!row) return bad(404, "not found");
    if (!pathInRoots(row.root)) return bad(403, "path out of bounds");
    return row;
  };

  app.get("/sessions/:id/browse", limit, async (req, reply) => {
    const r = rootOf((req.params as { id: string }).id);
    if ("status" in r) return reply.code(r.status).send({ error: r.error });
    const out = listDir(r.root, (req.query as { path?: unknown }).path);
    if ("status" in out) return reply.code(out.status).send({ error: out.error });
    return out;
  });

  app.get("/sessions/:id/browse/file", limit, async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const r = rootOf(id);
    if ("status" in r) return reply.code(r.status).send({ error: r.error });
    const out = readText(r.root, (req.query as { path?: unknown }).path);
    if ("status" in out) return reply.code(out.status).send({ error: out.error });
    logEvent(db, "file.browse", (req as { device?: Device }).device?.id ?? null, `${id}:${out.path}:${out.size}`);
    return out;
  });
}
