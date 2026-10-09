// tmux manager — integration vs REAL tmux on a throwaway -L socket. The headline
// property: killing the attach pty DETACHES (session survives), only killSession
// kills. Everything M2's durability rests on. Skipped automatically if tmux isn't
// installed. Tears down its own tmux server.

import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { randomBytes } from "node:crypto";
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
