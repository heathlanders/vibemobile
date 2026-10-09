// system.ts (ADR 0019) — parsers on fixtures, alert thresholds, snapshot assembly
// with fake sources (fixed argv, unit validation), and monitor push de-duplication.

import test from "node:test";
import assert from "node:assert/strict";
import { openDb } from "./db.js";
import { computeAlerts, cpuPct, parseMeminfo, parseNetDev, parseNodeVersion, parseNvidia, parseProcStat, parsePs, parseTailscaleStatus, pickCpuTemp, servesPort, snapshot, startSystemMonitor, type Sources } from "./system.js";

const MEMINFO = `MemTotal:       16000000 kB
MemFree:          500000 kB
MemAvailable:    1000000 kB
SwapTotal:       4000000 kB
SwapFree:        3000000 kB
`;

test("parsers: meminfo, /proc/stat cpu, ps, nvidia-smi", () => {
  assert.deepEqual(parseMeminfo(MEMINFO), { total: 16384000000, available: 1024000000, swapTotal: 4096000000, swapFree: 3072000000 });
  const a = parseProcStat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3");
  const b = parseProcStat("cpu  150 0 150 750 150 0 0 0 0 0\n");
  assert.deepEqual(a, [200, 1000]);
  assert.equal(cpuPct(a, b), 50); // +100 busy of +200 total
  assert.equal(cpuPct(a, a), 0);
  assert.deepEqual(parsePs("  12 node    3.5 204800\n  7 kworker/0:1 0.0 0\ngarbage\n"), [
    { pid: 12, name: "node", cpuPct: 3.5, rssKb: 204800 },
    { pid: 7, name: "kworker/0:1", cpuPct: 0, rssKb: 0 },
  ]);
  assert.deepEqual(parseNvidia("NVIDIA GeForce GTX 1070, 12, 300, 8192, 51\n"), [
    { name: "NVIDIA GeForce GTX 1070", utilPct: 12, memUsedMb: 300, memTotalMb: 8192, tempC: 51 },
  ]);
  assert.deepEqual(parseNvidia(""), []);
});

const NETDEV = `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 873072371342 489242082    0    0    0     0          0         0 873072371342 489242082    0    0    0     0       0          0
  eno1: 19506957456 50311231    0 14688    0     0          0     27991 14664075567 48467506    0    0    0     0       0          0
tailscale0: 12863876  129486    0    0    0     0          0         0 447490464  121569    0    0    0     0       0          0
br-79429861f082: 910637662 15249684    0    0    0     0          0         0 9008674011 16027034    0    0    0     0       0          0
docker0:  979289   10157    0    0    0     0          0         0 170556357   40105    0    0    0     0       0          0
veth474245d: 1409943806 18387340    0    0    0     0          0         0 8146694421 29011649    0    0    0     0       0          0
`;

test("parseNetDev: real interfaces only, rx/tx byte counters", () => {
  assert.deepEqual(parseNetDev(NETDEV), [
    { iface: "eno1", rx: 19506957456, tx: 14664075567 },
    { iface: "tailscale0", rx: 12863876, tx: 447490464 },
  ]);
  assert.deepEqual(parseNetDev(""), []);
});

test("pickCpuTemp: package sensor of a CPU chip, else its first; null without one", () => {
  const coretemp = [
    { chip: "coretemp", label: "Core 0", milliC: 37000 },
    { chip: "coretemp", label: "Package id 0", milliC: 41000 },
  ];
  assert.equal(pickCpuTemp([{ chip: "acpitz", label: "", milliC: 27800 }, ...coretemp]), 41);
  assert.equal(pickCpuTemp([{ chip: "k10temp", label: "Tctl", milliC: 55500 }]), 56);
  assert.equal(pickCpuTemp([{ chip: "cpu_thermal", label: "", milliC: 48200 }]), 48);
  assert.equal(pickCpuTemp([{ chip: "acpitz", label: "", milliC: 27800 }]), null);
});

test("computeAlerts: memory, swap, disk, gpu thresholds", () => {
  const ok = computeAlerts({
    mem: { total: 100, available: 50, swapTotal: 100, swapFree: 90 },
    disks: [{ path: "/", total: 100, free: 50 }],
    gpus: [{ name: "g", utilPct: 0, memUsedMb: 0, memTotalMb: 1, tempC: 60 }],
  });
  assert.deepEqual(ok, []);
  const bad = computeAlerts({
    mem: { total: 100, available: 5, swapTotal: 100, swapFree: 10 },
    disks: [{ path: "/", total: 100, free: 8 }],
    gpus: [{ name: "g", utilPct: 0, memUsedMb: 0, memTotalMb: 1, tempC: 90 }],
  });
  assert.deepEqual(bad.map((a) => a.key), ["mem", "swap", "disk:/", "gpu:0"]);
  assert.equal(bad[2].message, "Disk / 92% full");
});

function fakeSources(calls: [string, string[]][] = []): Sources {
  let stat = 0;
  return {
    read: (p) =>
      ({
        "/proc/stat": stat++ === 0 ? "cpu  100 0 100 700 100 0 0 0\n" : "cpu  150 0 150 750 150 0 0 0\n",
        "/proc/meminfo": MEMINFO,
        "/proc/loadavg": "0.50 0.40 0.30 1/200 999\n",
        "/proc/uptime": "3600.5 100.0\n",
        "/proc/net/dev": NETDEV,
        "/sys/class/hwmon/hwmon0/name": "acpitz\n",
        "/sys/class/hwmon/hwmon0/temp1_input": "27800\n",
        "/sys/class/hwmon/hwmon2/name": "coretemp\n",
        "/sys/class/hwmon/hwmon2/temp1_input": "41000\n",
        "/sys/class/hwmon/hwmon2/temp1_label": "Package id 0\n",
        "/sys/class/hwmon/hwmon2/temp2_input": "37000\n",
        "/sys/class/hwmon/hwmon2/temp2_label": "Core 0\n",
      })[p] ?? "",
    list: (d) =>
      ({
        "/sys/class/hwmon": ["hwmon0", "hwmon2"],
        "/sys/class/hwmon/hwmon0": ["name", "temp1_input"],
        "/sys/class/hwmon/hwmon2": ["name", "temp1_input", "temp1_label", "temp2_input", "temp2_label"],
      })[d] ?? [],
    statfs: (p) => (p === "/" ? { total: 1000, free: 50, dev: 1 } : p === "/home" ? { total: 1000, free: 50, dev: 1 } : null),
    run: async (cmd, args) => {
      calls.push([cmd, args]);
      if (cmd === "ps") return "1 init 0.1 1000\n";
      if (cmd === "systemctl") return args[0] === "--user" ? "active\n" : "active\ninactive\n";
      return ""; // no nvidia-smi
    },
    sleep: async () => {},
  };
}

test("snapshot assembles everything; disks deduped by device; units validated", async () => {
  const saved = process.env.VIBE_SYSTEM_UNITS;
  process.env.VIBE_SYSTEM_UNITS = "tailscaled,--now,earlyoom";
  try {
    const calls: [string, string[]][] = [];
    const s = await snapshot(fakeSources(calls));
    assert.equal(s.cpu.pct, 50);
    assert.equal(s.cpu.tempC, 41);
    assert.deepEqual(s.net.map((n) => n.iface), ["eno1", "tailscale0"]);
    assert.deepEqual(s.load, [0.5, 0.4, 0.3]);
    assert.equal(s.uptimeSec, 3601);
    assert.deepEqual(s.disks, [{ path: "/", total: 1000, free: 50 }]); // /home is the same fs
    assert.deepEqual(s.gpus, []);
    assert.deepEqual(s.services, [
      { name: "tailscaled", scope: "system", state: "active" },
      { name: "earlyoom", scope: "system", state: "inactive" },
      { name: "vibe-daemon", scope: "user", state: "active" },
    ]);
    assert.deepEqual(s.alerts.map((a) => a.key), ["mem", "disk:/"]); // fixture: 6% memory available
    const sysctl = calls.find(([c, a]) => c === "systemctl" && a[0] === "is-active")!;
    assert.deepEqual(sysctl[1], ["is-active", "--", "tailscaled", "earlyoom"], "flag-like unit dropped");
  } finally {
    if (saved === undefined) delete process.env.VIBE_SYSTEM_UNITS;
    else process.env.VIBE_SYSTEM_UNITS = saved;
  }
});

test("monitor pushes once per alert, re-arms after it clears", async () => {
  const db = openDb(":memory:");
  let full = true;
  const src: Sources = {
    ...fakeSources(),
    read: (p) => (p === "/proc/meminfo" ? MEMINFO.replace("MemAvailable:    1000000", full ? "MemAvailable:     100000" : "MemAvailable:    8000000") : ""),
    statfs: () => null,
  };
  const pushes: string[] = [];
  const stop = startSystemMonitor(db, { intervalMs: 20, src, notify: (_db, type) => pushes.push(type) });
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  await sleep(120);
  assert.deepEqual(pushes, ["system_alert"], "repeated ticks don't re-push");
  full = false;
  await sleep(80);
  full = true;
  await sleep(80);
  stop();
  assert.equal(pushes.length, 2, "cleared then returned → pushes again");
  const ev = db.prepare("SELECT detail FROM events WHERE kind = 'system.alert'").all() as any[];
  assert.match(ev[0].detail, /Memory 99% used/);
});

// ---- diagnostics (proposal 29) ---------------------------------------------

const TS_STATUS = (state: string) =>
  JSON.stringify({
    BackendState: state,
    Self: { DNSName: "box.tail1.ts.net.", TailscaleIPs: ["100.1.2.3"] },
    Peer: { k1: { DNSName: "phone.tail1.ts.net.", TailscaleIPs: ["100.9.9.9"] } },
  });
const SERVE = JSON.stringify({ Web: { "box.tail1.ts.net:443": { Handlers: { "/": { Proxy: "http://127.0.0.1:8787" } } } } });

function diagSources(state: string, serve: string, shellOut: string, calls: [string, string[]][] = []): Sources {
  const base = fakeSources(calls);
  return {
    ...base,
    run: async (cmd, args) => {
      calls.push([cmd, args]);
      if (cmd === "tailscale") return args[0] === "status" ? TS_STATUS(state) : serve;
      if (cmd === "env") return shellOut;
      return base.run(cmd, args);
    },
  };
}

test("diagnostic parsers: tailscale state/name, serve mapping, node version", () => {
  assert.deepEqual(parseTailscaleStatus(TS_STATUS("NeedsLogin")), { state: "NeedsLogin", dnsName: "box.tail1.ts.net" });
  assert.equal(parseTailscaleStatus(""), null, "missing binary → unavailable");
  assert.equal(servesPort(SERVE, 8787), true);
  assert.equal(servesPort(JSON.stringify({ TCP: { "8443": { TCPForward: "localhost:8787" } } }), 8787), true);
  assert.equal(servesPort(SERVE, 9999), false);
  assert.equal(servesPort(JSON.stringify({ Web: { x: { Handlers: { "/": { Proxy: "http://10.0.0.5:8787" } } } } }), 8787), false, "only a local target counts");
  assert.equal(parseNodeVersion("welcome!\nv20.20.2\n"), "v20.20.2");
  assert.equal(parseNodeVersion("bash: node: command not found"), null);
});

test("snapshot diagnostics: logged-out tailscale alerts, node drift flagged, no peer list", async () => {
  const shellMajor = Number(process.version.slice(1).split(".")[0]) + 2;
  const s = await snapshot(diagSources("NeedsLogin", SERVE, `v${shellMajor}.0.0\n`));
  assert.deepEqual(s.diagnostics.tailscale, { available: true, state: "NeedsLogin", dnsName: "box.tail1.ts.net", serving: true });
  assert.equal(s.diagnostics.node.daemon, process.version);
  assert.equal(s.diagnostics.node.mismatch, true);
  assert.ok(s.alerts.some((a) => a.key === "tailscale" && /NeedsLogin/.test(a.message)));
  assert.doesNotMatch(JSON.stringify(s), /phone\.tail1|100\.9\.9\.9|100\.1\.2\.3/, "peers and IPs stay server-side");

  const ok = await snapshot(diagSources("Running", "{}", `${process.version}\n`));
  assert.equal(ok.diagnostics.node.mismatch, false);
  assert.deepEqual(ok.alerts.filter((a) => a.key.startsWith("tailscale")).map((a) => a.key), ["tailscale-serve"]);
});

test("diagnostics are cached between polls (no bash spawn every 3 s)", async () => {
  const calls: [string, string[]][] = [];
  const src = diagSources("Running", SERVE, "v20.0.0\n", calls);
  await snapshot(src);
  await snapshot(src);
  assert.equal(calls.filter(([c]) => c === "env").length, 1);
  assert.deepEqual(calls.find(([c]) => c === "env")![1].slice(-3), ["bash", "-ic", "node -v"], "fixed argv");
});
