// Daemon entrypoint. Binds localhost only — `tailscale serve` is the sole
// ingress (PLAN §5 / security #1 / ADR 0005). Never bind 0.0.0.0.

import { openDb } from "./db.js";
import { buildApp } from "./app.js";
import { realTmux } from "./tmux.js";
import { startIdleReaper, type ClaudeRegistry } from "./claude.js";
import { startSystemMonitor } from "./system.js";
import { startUsageNudger } from "./usage.js";
import { startHookSocket } from "./hook.js";
import { startScheduler } from "./schedule.js";
import { purgeInternalTranscriptRows } from "./discover.js";
import { recoverMergeQueue } from "./merge-queue.js";

const HOST = "127.0.0.1";
const PORT = Number(process.env.PORT ?? 8787);

const db = openDb();
const tmux = realTmux();
await tmux.ensureGlobals(); // tmux -L vibe globals before any session create
await tmux.sweepStale(db); // mark sessions whose tmux died (e.g. reboot) as stale
purgeInternalTranscriptRows(db); // hide titler/Improve-prompt transcripts listed as sessions

const registry: ClaudeRegistry = new Map();
const app = await buildApp(db, tmux, registry);
await app.listen({ host: HOST, port: PORT });
await recoverMergeQueue({ db, registry }); // abort/clean items a restart left mid-rebase or mid-test, requeue them (ADR 0032 §3)
startIdleReaper(registry, db); // evict detached, idle claude SDK subprocesses
startSystemMonitor(db); // low memory/disk → phone push (ADR 0019)
startUsageNudger(db); // plan window resetting with capacity unused → phone push (ADR 0020)
startScheduler(db, registry); // scheduled prompts (proposal 44)
startHookSocket(db, registry); // CLI-session pushes via a Claude Code hook (ADR 0014)
console.log(`[vibe-daemon] listening http://${HOST}:${PORT} (localhost only)`);
