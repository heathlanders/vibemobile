// tmux manager — integration vs REAL tmux on a throwaway -L socket. The headline
// property: killing the attach pty DETACHES (session survives), only killSession
// kills. Everything M2's durability rests on. Skipped automatically if tmux isn't
// installed. Tears down its own tmux server.

import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { realTmux } from "./tmux.js";

const execFileP = promisify(execFile);
const SOCK = "vibetest-" + randomBytes(4).toString("hex");
const tmux = realTmux(SOCK);

const tmuxInstalled = await execFileP("tmux", ["-V"]).then(
  () => true,
  () => false,
);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("tmux session: create → attach → detach (survives) → kill", { skip: !tmuxInstalled }, async (t) => {
  t.after(() => execFileP("tmux", ["-L", SOCK, "kill-server"]).catch(() => {}));

  await tmux.ensureGlobals();
  const id = randomBytes(4).toString("hex");

  assert.equal(await tmux.hasSession(id), false, "no session before create");
  await tmux.createSession(id, process.env.HOME ?? "/tmp");
  assert.equal(await tmux.hasSession(id), true, "session exists after create");

  // Attach, drop a marker into the shell, confirm it round-trips through tmux.
  const term = tmux.attach(id, 80, 24);
  let buf = "";
  term.onData((d) => (buf += d));
  await sleep(300);
  term.write("echo VIBE_MARKER_$((6*7))\n");
  await sleep(500);
  assert.match(buf, /VIBE_MARKER_42/, "marker echoed back through the attach");

  // Kill the attach pty = detach. Session MUST survive.
  term.kill();
  await sleep(300);
  assert.equal(await tmux.hasSession(id), true, "session survives the attach pty being killed (detach ≠ kill)");

  // Re-attach: scrollback still has the marker (tmux redraw, no replay buffer).
  const term2 = tmux.attach(id, 80, 24);
  let buf2 = "";
  term2.onData((d) => (buf2 += d));
  await sleep(500);
  assert.match(buf2, /VIBE_MARKER_42/, "reattach redraws prior scrollback");
  term2.kill();
  await sleep(200);

  // Explicit kill = gone.
  await tmux.killSession(id);
  assert.equal(await tmux.hasSession(id), false, "killSession ends it");
});

// Proposal 69 R4: a tmux server forked by the daemon used to live in the daemon's
// own cgroup, so `systemctl restart` (KillMode=control-group) killed every terminal.
// Started inside its own `systemd-run --user --scope`, it outlives the service.
const systemdUser = await execFileP("systemd-run", ["--user", "--scope", "--quiet", "--collect", "--", "/bin/true"]).then(
  () => true,
  () => false,
);
test("tmux server runs in its own systemd scope, not the caller's cgroup", { skip: !tmuxInstalled || !systemdUser }, async (t) => {
  const sock = SOCK + "-scope";
  const tmux = realTmux(sock);
  t.after(async () => {
    await execFileP("tmux", ["-L", sock, "kill-server"]).catch(() => {});
  });
  await tmux.createSession("s_scope", "/tmp");
  const { stdout } = await execFileP("tmux", ["-L", sock, "display-message", "-p", "#{pid}"]);
  const serverCg = readFileSync(`/proc/${stdout.trim()}/cgroup`, "utf8").trim();
  const ownCg = readFileSync("/proc/self/cgroup", "utf8").trim();
  assert.notEqual(serverCg, ownCg, "not in the daemon's cgroup");
  assert.match(serverCg, /\.scope$/);
});
