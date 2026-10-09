/// `GET /system` (ADR 0019): a read-only health snapshot of the server.
class SystemSnapshot {
  const SystemSnapshot({
    required this.hostname,
    required this.uptimeSec,
    required this.load,
    required this.cores,
    required this.cpuPct,
    this.cpuTempC,
    required this.memTotal,
    required this.memAvailable,
    required this.swapTotal,
    required this.swapFree,
    required this.disks,
    this.net = const [],
    required this.gpus,
    required this.top,
    required this.services,
    this.diagnostics,
    required this.alerts,
    this.footprint = const [],
    this.diskAlertPercent = 90,
    this.dataAlertGb = 0,
  });

  final String hostname;
  final int uptimeSec;
  final List<double> load;
  final int cores;
  final double cpuPct;
  final int? cpuTempC; // null: no CPU sensor on the box
  final int memTotal, memAvailable, swapTotal, swapFree; // bytes
  final List<DiskUsage> disks;
  final List<NetIface> net;
  final List<GpuStat> gpus;
  final List<ProcStat> top;
  final List<ServiceState> services;
  final Diagnostics? diagnostics; // null from daemons before proposal 29
  final List<String> alerts; // human-readable, already thresholded server-side

  /// Disk the daemon itself grows (transcripts, rewind backups, DB, worktrees; ADR 0026).
  /// Empty from older daemons.
  final List<FootprintItem> footprint;

  /// The server's alert thresholds, so meters turn red exactly when the alert fires.
  final num diskAlertPercent;
  final num dataAlertGb; // 0 = alert off

  double get memUsedFrac => memTotal == 0 ? 0 : (memTotal - memAvailable) / memTotal;
  double get swapUsedFrac => swapTotal == 0 ? 0 : (swapTotal - swapFree) / swapTotal;

  factory SystemSnapshot.fromJson(Map<String, dynamic> j) {
    final cpu = (j['cpu'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mem = (j['mem'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        ((j[k] as List?) ?? const []).map((e) => f((e as Map).cast<String, dynamic>())).toList();
    return SystemSnapshot(
      hostname: (j['hostname'] as String?) ?? '',
      uptimeSec: (j['uptimeSec'] as num?)?.toInt() ?? 0,
      load: ((j['load'] as List?) ?? const []).map((e) => (e as num).toDouble()).toList(),
      cores: n(cpu, 'cores'),
      cpuPct: (cpu['pct'] as num?)?.toDouble() ?? 0,
      cpuTempC: (cpu['tempC'] as num?)?.toInt(),
      memTotal: n(mem, 'total'),
      memAvailable: n(mem, 'available'),
      swapTotal: n(mem, 'swapTotal'),
      swapFree: n(mem, 'swapFree'),
      disks: list('disks', (m) => DiskUsage(m['path'] as String, n(m, 'total'), n(m, 'free'))),
      net: list('net', (m) => NetIface(m['iface'] as String, n(m, 'rx'), n(m, 'tx'))),
      gpus: list(
        'gpus',
        (m) => GpuStat(m['name'] as String, n(m, 'utilPct'), n(m, 'memUsedMb'), n(m, 'memTotalMb'), n(m, 'tempC')),
      ),
      top: list('top', (m) => ProcStat(n(m, 'pid'), m['name'] as String, (m['cpuPct'] as num?)?.toDouble() ?? 0, n(m, 'rssKb'))),
      services: list('services', (m) => ServiceState(m['name'] as String, m['scope'] as String, m['state'] as String)),
      diagnostics: j['diagnostics'] is Map ? Diagnostics.fromJson((j['diagnostics'] as Map).cast<String, dynamic>()) : null,
      alerts: list('alerts', (m) => m['message'] as String),
      footprint: list('footprint', (m) => FootprintItem(m['label'] as String, n(m, 'bytes'), m['truncated'] == true)),
      diskAlertPercent: ((j['limits'] as Map?)?['diskPercent'] as num?) ?? 90,
      dataAlertGb: ((j['limits'] as Map?)?['dataAlertGb'] as num?) ?? 0,
    );
  }
}

/// One line of the daemon's own disk use. [truncated]: the walk hit its entry cap, so
/// [bytes] is a lower bound.
class FootprintItem {
  const FootprintItem(this.label, this.bytes, [this.truncated = false]);
  final String label;
  final int bytes;
  final bool truncated;
}

/// Connectivity + runtime checks (proposal 29) — what a running unit doesn't show.
class Diagnostics {
  const Diagnostics({
    required this.tailscaleAvailable,
    this.tailscaleState,
    this.dnsName,
    required this.serving,
    required this.daemonNode,
    this.shellNode,
    required this.nodeMismatch,
    required this.daemonUptimeSec,
    this.sdkVersion,
    required this.fcm,
  });

  final bool tailscaleAvailable;
  final String? tailscaleState; // Running | NeedsLogin | Stopped | …
  final String? dnsName;
  final bool serving; // `tailscale serve` still forwards to the daemon port
  final String daemonNode;
  final String? shellNode; // what a fresh terminal's `node` is
  final bool nodeMismatch; // major versions differ
  final int daemonUptimeSec;
  final String? sdkVersion;
  final bool fcm;

  factory Diagnostics.fromJson(Map<String, dynamic> j) {
    Map<String, dynamic> m(String k) => (j[k] as Map?)?.cast<String, dynamic>() ?? const {};
    final ts = m('tailscale'), node = m('node'), d = m('daemon');
    return Diagnostics(
      tailscaleAvailable: ts['available'] == true,
      tailscaleState: ts['state'] as String?,
      dnsName: ts['dnsName'] as String?,
      serving: ts['serving'] == true,
      daemonNode: (node['daemon'] as String?) ?? '?',
      shellNode: node['shell'] as String?,
      nodeMismatch: node['mismatch'] == true,
      daemonUptimeSec: (d['uptimeSec'] as num?)?.toInt() ?? 0,
      sdkVersion: d['sdkVersion'] as String?,
      fcm: d['fcm'] == true,
    );
  }
}

/// Plain-language fixes for whatever [d] flags (proposal 29). Pure → unit-tested.
List<String> diagnosticHints(Diagnostics d) {
  final out = <String>[];
  if (!d.tailscaleAvailable) {
    out.add("Couldn't read Tailscale status on the server (is the tailscale CLI installed?).");
  } else if (d.tailscaleState != 'Running') {
    out.add('Tailscale is ${d.tailscaleState ?? 'not running'}: run `sudo tailscale up` on the server, or open the '
        'AuthURL from `tailscale status --json`. The serve mapping comes back by itself after login.');
  } else if (!d.serving) {
    out.add("`tailscale serve` isn't forwarding to the daemon: run `sudo tailscale serve --bg 8787` on the server.");
  }
  if (d.nodeMismatch) {
    out.add('The daemon runs Node ${d.daemonNode} but a terminal picks ${d.shellNode}. Running `npm install` in vibe-daemon '
        'from that terminal rebuilds native modules for the wrong Node, and the daemon then fails on restart.');
  }
  if (!d.fcm) out.add('Push is off: no Firebase credentials on the server.');
  return out;
}

class DiskUsage {
  const DiskUsage(this.path, this.total, this.free);
  final String path;
  final int total, free;
  double get usedFrac => total == 0 ? 0 : (total - free) / total;
}

/// Byte counters since boot; rates come from two snapshots ([netRates]).
class NetIface {
  const NetIface(this.iface, this.rx, this.tx);
  final String iface;
  final int rx, tx;
}

/// Bytes/second per interface between two polls [seconds] apart. null rates
/// when there's no earlier reading or a counter went backwards (reboot).
List<({String iface, double? rx, double? tx})> netRates(SystemSnapshot? prev, SystemSnapshot cur, double seconds) {
  final before = {for (final n in prev?.net ?? const <NetIface>[]) n.iface: n};
  double? rate(int? a, int b) => a == null || b < a || seconds <= 0 ? null : (b - a) / seconds;
  return [
    for (final n in cur.net) (iface: n.iface, rx: rate(before[n.iface]?.rx, n.rx), tx: rate(before[n.iface]?.tx, n.tx)),
  ];
}

/// "1.2 MB/s" / "340 KB/s" / "12 B/s".
String rateLabel(double bps) {
  const kb = 1024, mb = 1024 * 1024;
  if (bps >= mb) return '${(bps / mb).toStringAsFixed(1)} MB/s';
  if (bps >= kb) return '${(bps / kb).round()} KB/s';
  return '${bps.round()} B/s';
}

class GpuStat {
  const GpuStat(this.name, this.utilPct, this.memUsedMb, this.memTotalMb, this.tempC);
  final String name;
  final int utilPct, memUsedMb, memTotalMb, tempC;
}

class ProcStat {
  const ProcStat(this.pid, this.name, this.cpuPct, this.rssKb);
  final int pid;
  final String name;
  final double cpuPct;
  final int rssKb;
}

class ServiceState {
  const ServiceState(this.name, this.scope, this.state);
  final String name, scope, state;
  bool get active => state == 'active';
}

/// "4.0 GB" / "512 MB". Pure → unit-tested.
String bytesLabel(int b) {
  const gb = 1024 * 1024 * 1024, mb = 1024 * 1024;
  return b >= gb ? '${(b / gb).toStringAsFixed(1)} GB' : '${(b / mb).round()} MB';
}

/// "7d 3h" / "5h 12m" / "4m".
String uptimeLabel(int sec) {
  final d = sec ~/ 86400, h = (sec % 86400) ~/ 3600, m = (sec % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
