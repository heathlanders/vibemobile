// System monitor (ADR 0019, roadmap phase 5). READ-ONLY view of the box: CPU,
// load, CPU temperature, memory/swap, disks, network counters, GPU, top
// processes and the status of a fixed set of services, plus low-resource alerts
// pushed to the phone.
//
// Security: nothing here writes, kills or restarts anything. External commands
// are fixed argv arrays via execFile (no shell); the only configurable inputs —
// unit names and disk paths from the daemon's own env — are validated before use.

import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import type { FastifyInstance } from "fastify";
import type { DB } from "./db.js";
import { logEvent } from "./auth.js";
import { fcmConfigured, notifyDevices } from "./push.js";
import { daemonDataAlertGb, diskAlertPercent } from "./settings.js";
import { footprint, totalBytes, type FootprintItem } from "./footprint.js";

export type Snapshot = {
  ts: string;
  hostname: string;
  uptimeSec: number;
  load: [number, number, number];
  cpu: { cores: number; pct: number; tempC: number | null };
  mem: { total: number; available: number; swapTotal: number; swapFree: number }; // bytes
  disks: { path: string; total: number; free: number }[]; // bytes
  net: { iface: string; rx: number; tx: number }[]; // byte counters since boot; the client derives rates
  gpus: { name: string; utilPct: number; memUsedMb: number; memTotalMb: number; tempC: number }[];
  top: { pid: number; name: string; cpuPct: number; rssKb: number }[];
  services: { name: string; scope: "system" | "user"; state: string }[];
  diagnostics: Diagnostics;
  // Disk the daemon itself grows (footprint.ts); [] when no DB was supplied (tests).
  footprint: { label: string; bytes: number; truncated?: boolean }[];
  // The alert thresholds in force (settings.ts) so a client can colour meters the same way.
  limits: { diskPercent: number; dataAlertGb: number };
  alerts: { key: string; message: string }[];
};

// Proposal 29: what broke us before (Tailscale logged out, shell/daemon Node
// drift) but a running unit doesn't show. Whitelisted fields only — never the
// tailnet peer list.
export type Diagnostics = {
  tailscale: { available: boolean; state: string | null; dnsName: string | null; serving: boolean };
  node: { daemon: string; shell: string | null; mismatch: boolean };
  daemon: { uptimeSec: number; sdkVersion: string | null; fcm: boolean };
};

// ---- pure parsers (unit-tested with fixtures) ------------------------------

export function parseMeminfo(text: string): Snapshot["mem"] {
  const kb = (k: string) => Number(new RegExp(`^${k}:\\s+(\\d+)`, "m").exec(text)?.[1] ?? 0) * 1024;
  return { total: kb("MemTotal"), available: kb("MemAvailable"), swapTotal: kb("SwapTotal"), swapFree: kb("SwapFree") };
}

// Aggregate "cpu" line → [busy, total] jiffies.
export function parseProcStat(text: string): [number, number] {
  const f = (/^cpu\s+(.+)$/m.exec(text)?.[1] ?? "").trim().split(/\s+/).map(Number);
  const idle = (f[3] ?? 0) + (f[4] ?? 0); // idle + iowait
  const total = f.slice(0, 8).reduce((a, b) => a + (b || 0), 0); // user..steal
  return [total - idle, total];
}

export function cpuPct(a: [number, number], b: [number, number]): number {
  const dt = b[1] - a[1];
  return dt > 0 ? Math.round(((b[0] - a[0]) / dt) * 1000) / 10 : 0;
}

// `ps -eo pid,comm,pcpu,rss --sort=-rss --no-headers`
export function parsePs(text: string, limit = 8): Snapshot["top"] {
  return text
    .split("\n")
    .map((l) => /^\s*(\d+)\s+(.+?)\s+([\d.]+)\s+(\d+)\s*$/.exec(l))
    .filter((m): m is RegExpExecArray => !!m)
    .slice(0, limit)
    .map((m) => ({ pid: Number(m[1]), name: m[2], cpuPct: Number(m[3]), rssKb: Number(m[4]) }));
}

// /proc/net/dev → per-interface byte counters. Loopback and container plumbing
// (veth*, br-*, docker*, virbr*) are dropped: they double-count real traffic.
const VIRTUAL_IFACE = /^(lo|veth|br-|docker|virbr)/;
export function parseNetDev(text: string): Snapshot["net"] {
  return text
    .split("\n")
    .map((l) => /^\s*([^:\s]+):\s*(.+)$/.exec(l))
    .filter((m): m is RegExpExecArray => !!m && !VIRTUAL_IFACE.test(m[1]))
    .map((m) => {
      const f = m[2].trim().split(/\s+/).map(Number);
      return { iface: m[1], rx: f[0] || 0, tx: f[8] || 0 };
    });
}

// CPU package temperature from hwmon sensors: the CPU driver's package /
// Tctl / Tdie reading, else its first sensor. null when there's no CPU sensor.
const CPU_HWMON = new Set(["coretemp", "k10temp", "zenpower", "cpu_thermal"]);
export function pickCpuTemp(sensors: { chip: string; label: string; milliC: number }[]): number | null {
  const cpu = sensors.filter((x) => CPU_HWMON.has(x.chip) && Number.isFinite(x.milliC));
  const pkg = cpu.find((x) => /^(Package id \d+|Tctl|Tdie)$/.test(x.label)) ?? cpu[0];
  return pkg ? Math.round(pkg.milliC / 1000) : null;
}

// `nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits`
export function parseNvidia(text: string): Snapshot["gpus"] {
  return text
    .split("\n")
    .map((l) => l.split(",").map((s) => s.trim()))
    .filter((c) => c.length >= 5 && c[0])
    .map((c) => ({ name: c[0], utilPct: Number(c[1]) || 0, memUsedMb: Number(c[2]) || 0, memTotalMb: Number(c[3]) || 0, tempC: Number(c[4]) || 0 }));
}

// `tailscale status --json` → BackendState + this node's MagicDNS name only.
export function parseTailscaleStatus(text: string): { state: string | null; dnsName: string | null } | null {
  try {
    const j = JSON.parse(text);
    const dns = typeof j?.Self?.DNSName === "string" ? j.Self.DNSName.replace(/\.$/, "") : null;
    return { state: typeof j?.BackendState === "string" ? j.BackendState : null, dnsName: dns || null };
  } catch {
    return null;
  }
}

// `tailscale serve status --json` → does any handler still reach the daemon port?
export function servesPort(text: string, port: number): boolean {
  let j: any;
  try {
    j = JSON.parse(text);
  } catch {
    return false;
  }
  const local = new RegExp(`^(https?://)?(127\\.0\\.0\\.1|localhost):${port}/?$`);
  const tcp = Object.values(j?.TCP ?? {}).some((t: any) => typeof t?.TCPForward === "string" && local.test(t.TCPForward));
  const web = Object.values(j?.Web ?? {}).some((w: any) =>
    Object.values(w?.Handlers ?? {}).some((h: any) => typeof h?.Proxy === "string" && local.test(h.Proxy)),
  );
  return tcp || web;
}

// "v20.20.2" from an interactive shell's output (a noisy .bashrc may print more).
export function parseNodeVersion(text: string): string | null {
  return /^v\d+\.\d+\.\d+\s*$/m.exec(text)?.[0].trim() ?? null;
}
export const majorOf = (v: string) => Number(/^v(\d+)/.exec(v)?.[1] ?? NaN);

// Thresholds: memory < 10% available, swap > 50% used, any disk > `diskPercent`
// (default 90, setting disk.alert_percent — ADR 0026) used, GPU ≥ 85 °C. Keys are
// stable so the monitor can de-duplicate pushes.
export function computeAlerts(
  s: Pick<Snapshot, "mem" | "disks" | "gpus"> & { diagnostics?: Diagnostics },
  diskPercent = 90,
  data?: { items: FootprintItem[]; limitGb: number }, // the daemon's own growth (footprint.ts); limit 0 = off
): Snapshot["alerts"] {
  const out: Snapshot["alerts"] = [];
  // Tailscale down = the phone can't reach us, but FCM still can (proposal 29).
  const ts = s.diagnostics?.tailscale;
  if (ts?.available && ts.state && ts.state !== "Running") {
    out.push({ key: "tailscale", message: `Tailscale is ${ts.state} — run \`sudo tailscale up\` on the server` });
  } else if (ts?.available && ts.state === "Running" && !ts.serving) {
    out.push({ key: "tailscale-serve", message: "tailscale serve no longer forwards to the daemon" });
  }
  const pct = (used: number, total: number) => Math.round((used / total) * 100);
  if (s.mem.total > 0 && s.mem.available / s.mem.total < 0.1) {
    out.push({ key: "mem", message: `Memory ${pct(s.mem.total - s.mem.available, s.mem.total)}% used` });
  }
  if (s.mem.swapTotal > 0 && (s.mem.swapTotal - s.mem.swapFree) / s.mem.swapTotal > 0.5) {
    out.push({ key: "swap", message: `Swap ${pct(s.mem.swapTotal - s.mem.swapFree, s.mem.swapTotal)}% used` });
  }
  for (const d of s.disks) {
    if (d.total > 0 && (d.total - d.free) / d.total > diskPercent / 100) {
      out.push({ key: `disk:${d.path}`, message: `Disk ${d.path} ${pct(d.total - d.free, d.total)}% full` });
    }
  }
  if (data && data.limitGb > 0) {
    const total = totalBytes(data.items);
    if (total > data.limitGb * 1e9) {
      const top = [...data.items].sort((a, b) => b.bytes - a.bytes)[0];
      out.push({
        key: "daemon-data",
        message: `Daemon data is ${(total / 1e9).toFixed(1)} GB (mostly ${top.label.toLowerCase()}) — delete old sessions in the app`,
      });
    }
  }
  for (const [i, g] of s.gpus.entries()) {
    if (g.tempC >= 85) out.push({ key: `gpu:${i}`, message: `GPU ${g.name} at ${g.tempC} °C` });
  }
  return out;
}

// ---- sources (injectable for tests) ----------------------------------------

export type Sources = {
  read: (path: string) => string;
  list: (dir: string) => string[]; // entry names; [] on any failure
  statfs: (path: string) => { total: number; free: number; dev: number } | null;
  run: (cmd: string, args: string[]) => Promise<string>; // "" on any failure
  sleep: (ms: number) => Promise<void>;
};

const realSources: Sources = {
  read: (p) => fs.readFileSync(p, "utf8"),
  list: (d) => {
    try {
      return fs.readdirSync(d);
    } catch {
      return [];
    }
  },
  statfs: (p) => {
    try {
      const s = fs.statfsSync(p);
      return { total: s.blocks * s.bsize, free: s.bavail * s.bsize, dev: fs.statSync(p).dev };
    } catch {
      return null;
    }
  },
  run: (cmd, args) =>
    new Promise((resolve) =>
      execFile(cmd, args, { timeout: 3000 }, (_err, stdout) => resolve(String(stdout ?? ""))),
    ),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
};

// Env lists: unit names / paths only — no leading '-', so nothing reads as a flag.
const UNIT = /^[A-Za-z0-9@_.:][A-Za-z0-9@_.:-]*$/;
function list(env: string | undefined, fallback: string[], ok: (s: string) => boolean): string[] {
  return (env ? env.split(",") : fallback).map((s) => s.trim()).filter((s) => s && ok(s));
}
const systemUnits = () => list(process.env.VIBE_SYSTEM_UNITS, ["tailscaled", "earlyoom"], (u) => UNIT.test(u));
const userUnits = () => list(process.env.VIBE_USER_UNITS, ["vibe-daemon"], (u) => UNIT.test(u));
const diskPaths = () => list(process.env.VIBE_DISKS, ["/", "/home"], (p) => p.startsWith("/"));

const PORT = () => Number(process.env.PORT ?? 8787);
const SDK_PKG = new URL("../node_modules/@anthropic-ai/claude-agent-sdk/package.json", import.meta.url);

export async function diagnostics(src: Sources = realSources): Promise<Diagnostics> {
  const [status, serve, shellNode] = await Promise.all([
    src.run("tailscale", ["status", "--json"]),
    src.run("tailscale", ["serve", "status", "--json"]),
    // The Node a fresh terminal picks (nvm lives in .bashrc → interactive). Clean
    // env: inherited npm_* vars make nvm refuse to switch versions.
    src.run("env", ["-i", `HOME=${os.homedir()}`, "PATH=/usr/local/bin:/usr/bin:/bin", "bash", "-ic", "node -v"]),
  ]);
  const ts = parseTailscaleStatus(status);
  const shell = parseNodeVersion(shellNode);
  let sdkVersion: string | null = null;
  try {
    sdkVersion = JSON.parse(src.read(SDK_PKG.pathname)).version ?? null;
  } catch {
    /* not installed where expected */
  }
  return {
    tailscale: { available: ts !== null, state: ts?.state ?? null, dnsName: ts?.dnsName ?? null, serving: servesPort(serve, PORT()) },
    node: { daemon: process.version, shell, mismatch: shell !== null && majorOf(shell) !== majorOf(process.version) },
    daemon: { uptimeSec: Math.round(process.uptime()), sdkVersion, fcm: fcmConfigured() },
  };
}

// /system is polled every ~3 s and spawning an interactive bash is not free:
// diagnostics refresh at most every 5 minutes per source.
const DIAG_TTL_MS = 5 * 60_000;
const diagCache = new WeakMap<Sources, { at: number; value: Promise<Diagnostics> }>();
function cachedDiagnostics(src: Sources): Promise<Diagnostics> {
  const hit = diagCache.get(src);
  if (hit && Date.now() - hit.at < DIAG_TTL_MS) return hit.value;
  const value = diagnostics(src);
  diagCache.set(src, { at: Date.now(), value });
  return value;
}

export type SnapshotOpts = { diskPercent?: number; db?: DB; dataSrc?: Parameters<typeof footprint>[1] };
export async function snapshot(src: Sources = realSources, opts: SnapshotOpts = {}): Promise<Snapshot> {
  const safeRead = (p: string) => {
    try {
      return src.read(p);
    } catch {
      return "";
    }
  };
  const a = parseProcStat(safeRead("/proc/stat"));
  const [ps, gpu, sysStates, userStates, diag] = await Promise.all([
    src.run("ps", ["-eo", "pid,comm,pcpu,rss", "--sort=-rss", "--no-headers"]),
    src.run("nvidia-smi", [
      "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
      "--format=csv,noheader,nounits",
    ]),
    systemUnits().length ? src.run("systemctl", ["is-active", "--", ...systemUnits()]) : Promise.resolve(""),
    userUnits().length ? src.run("systemctl", ["--user", "is-active", "--", ...userUnits()]) : Promise.resolve(""),
    cachedDiagnostics(src),
    src.sleep(250), // CPU sample window
  ]);
  const b = parseProcStat(safeRead("/proc/stat"));

  // One row per filesystem: /home on the root fs would just repeat /.
  const seen = new Set<number>();
  const disks: Snapshot["disks"] = [];
  for (const p of diskPaths()) {
    const s = src.statfs(p);
    if (!s || seen.has(s.dev)) continue;
    seen.add(s.dev);
    disks.push({ path: p, total: s.total, free: s.free });
  }

  const states = (out: string, names: string[], scope: "system" | "user") => {
    const lines = out.split("\n").filter(Boolean);
    return names.map((name, i) => ({ name, scope, state: lines[i] ?? "unknown" }));
  };
  const items = opts.db ? footprint(opts.db, opts.dataSrc) : [];
  const load = (safeRead("/proc/loadavg").split(/\s+/).slice(0, 3).map(Number) as [number, number, number]) ?? [0, 0, 0];
  const mem = parseMeminfo(safeRead("/proc/meminfo"));
  const gpus = parseNvidia(gpu);
  const sensors: { chip: string; label: string; milliC: number }[] = [];
  for (const h of src.list("/sys/class/hwmon")) {
    const dir = `/sys/class/hwmon/${h}`;
    const chip = safeRead(`${dir}/name`).trim();
    if (!CPU_HWMON.has(chip)) continue;
    for (const f of src.list(dir).filter((f) => /^temp\d+_input$/.test(f)).sort()) {
      const label = safeRead(`${dir}/${f.replace("_input", "_label")}`).trim();
      sensors.push({ chip, label, milliC: Number(safeRead(`${dir}/${f}`).trim()) });
    }
  }
  return {
    ts: new Date().toISOString(),
    hostname: os.hostname(),
    uptimeSec: Math.round(Number(safeRead("/proc/uptime").split(" ")[0]) || 0),
    load: load.map((n) => n || 0) as [number, number, number],
    cpu: { cores: os.cpus().length, pct: cpuPct(a, b), tempC: pickCpuTemp(sensors) },
    mem,
    disks,
    net: parseNetDev(safeRead("/proc/net/dev")),
    gpus,
    top: parsePs(ps),
    services: [...states(sysStates, systemUnits(), "system"), ...states(userStates, userUnits(), "user")],
    diagnostics: diag,
    footprint: items,
    limits: { diskPercent: opts.diskPercent ?? 90, dataAlertGb: opts.db ? daemonDataAlertGb(opts.db) : 0 },
    alerts: computeAlerts({ mem, disks, gpus, diagnostics: diag }, opts.diskPercent ?? 90, items.length ? { items, limitGb: opts.db ? daemonDataAlertGb(opts.db) : 0 } : undefined),
  };
}

export function registerSystemRoutes(app: FastifyInstance, db?: DB): void {
  app.get("/system", async () => snapshot(realSources, db ? { diskPercent: diskAlertPercent(db), db } : {}));
}

// Background check: push once when an alert starts, then stay quiet for
// [cooldownMs] unless it clears and comes back. Content-free push (ADR 0013):
// the phone just says the server needs attention.
export function startSystemMonitor(
  db: DB,
  { intervalMs = 60_000, cooldownMs = 6 * 3_600_000, src = realSources, notify = notifyDevices } = {},
): () => void {
  const lastPushed = new Map<string, number>();
  const tick = async () => {
    try {
      const { alerts } = await snapshot(src, { diskPercent: diskAlertPercent(db), db });
      const active = new Set(alerts.map((a) => a.key));
      for (const k of [...lastPushed.keys()]) if (!active.has(k)) lastPushed.delete(k); // cleared → re-arm
      const fresh = alerts.filter((a) => Date.now() - (lastPushed.get(a.key) ?? -Infinity) > cooldownMs);
      if (!fresh.length) return;
      for (const a of fresh) lastPushed.set(a.key, Date.now());
      logEvent(db, "system.alert", null, fresh.map((a) => a.message).join("; "));
      notify(db, "system_alert", "");
    } catch {
      /* monitoring must never take the daemon down */
    }
  };
  void tick();
  const timer = setInterval(tick, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}
