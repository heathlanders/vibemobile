import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/notifications/domain/push_note.dart';
import 'package:vibemobile/features/system/data/system_api.dart';
import 'package:vibemobile/features/system/domain/system_snapshot.dart';
import 'package:vibemobile/features/system/presentation/system_screen.dart';

// Shape captured from the live daemon (trimmed).
const live = {
  'hostname': 'snf',
  'uptimeSec': 624886,
  'load': [3.22, 3.15, 2.42],
  'cpu': {'cores': 4, 'pct': 26.9, 'tempC': 41},
  'mem': {'total': 16705454080, 'available': 4311351296, 'swapTotal': 4294963200, 'swapFree': 180224},
  'disks': [
    {'path': '/', 'total': 249322430464, 'free': 19291127808},
  ],
  'net': [
    {'iface': 'eno1', 'rx': 19506957456, 'tx': 14664075567},
    {'iface': 'tailscale0', 'rx': 12863876, 'tx': 447490464},
  ],
  'gpus': [
    {'name': 'NVIDIA GeForce GTX 1070', 'utilPct': 0, 'memUsedMb': 2, 'memTotalMb': 8192, 'tempC': 51},
  ],
  'top': [
    {'pid': 2586468, 'name': 'postgres', 'cpuPct': 0, 'rssKb': 2294372},
  ],
  'services': [
    {'name': 'tailscaled', 'scope': 'system', 'state': 'active'},
    {'name': 'earlyoom', 'scope': 'system', 'state': 'failed'},
  ],
  'alerts': [
    {'key': 'swap', 'message': 'Swap 100% used'},
    {'key': 'disk:/', 'message': 'Disk / 92% full'},
  ],
};

class _FakeApi extends SystemApi {
  _FakeApi() : super(Dio());
  @override
  Future<SystemSnapshot> snapshot() async => SystemSnapshot.fromJson(live);
}

void main() {
  footprintTests();
  test('SystemSnapshot parses the live shape', () {
    final s = SystemSnapshot.fromJson(live);
    expect(s.cores, 4);
    expect(s.memUsedFrac, closeTo(0.742, 0.001));
    expect(s.swapUsedFrac, closeTo(1.0, 0.001));
    expect(s.disks.single.usedFrac, closeTo(0.923, 0.001));
    expect(s.services.where((x) => !x.active).single.name, 'earlyoom');
    expect(s.alerts, ['Swap 100% used', 'Disk / 92% full']);
  });

  test('netRates: per-second deltas; null without a previous reading or after a reset', () {
    final a = SystemSnapshot.fromJson(live);
    final b = SystemSnapshot.fromJson({
      ...live,
      'net': [
        {'iface': 'eno1', 'rx': 19506957456 + 3 * 1024 * 1024, 'tx': 14664075567 + 3000},
        {'iface': 'tailscale0', 'rx': 0, 'tx': 0}, // counters reset
      ],
    });
    expect(a.cpuTempC, 41);
    expect(netRates(null, a, 0).first.rx, isNull);
    final r = netRates(a, b, 3);
    expect(rateLabel(r[0].rx!), '1.0 MB/s');
    expect(rateLabel(r[0].tx!), '1000 B/s');
    expect(r[1].rx, isNull);
    expect(rateLabel(340 * 1024), '340 KB/s');
  });

  test('labels', () {
    expect(bytesLabel(4294963200), '4.0 GB');
    expect(bytesLabel(512 * 1024 * 1024), '512 MB');
    expect(uptimeLabel(624886), '7d 5h');
    expect(uptimeLabel(3 * 3600 + 12 * 60), '3h 12m');
    expect(uptimeLabel(240), '4m');
  });

  test('system alert note: content-free, stable id, tap-only', () {
    final n = systemAlertNote();
    expect(n.id, stableNoteId('system_alert'));
    expect(n.actions, isEmpty);
    expect(NotePayload.decode(n.payload)?.kind, 'system');
  });

  testWidgets('SystemScreen shows alerts, meters, services and processes', (tester) async {
    final w = double.parse(Platform.environment['VIBE_W'] ?? '900');
    await tester.binding.setSurfaceSize(Size(w, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: SystemScreen(creds: const Creds('http://x', 't'), api: _FakeApi()),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('System · snf'), findsOneWidget);
    expect(find.text('Disk / 92% full'), findsOneWidget);
    expect(find.textContaining('· high'), findsNWidgets(2)); // swap + disk meters flagged
    expect(find.text('earlyoom · failed'), findsOneWidget);
    expect(find.text('postgres'), findsOneWidget);
    expect(find.text('41 °C'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('measuring…'), findsNWidgets(2)); // first reading: no rate yet
    if (Platform.environment['VIBE_RENDER'] != null) {
      await expectLater(find.byType(SystemScreen), matchesGoldenFile(Platform.environment['VIBE_RENDER']!));
    }
    await tester.pumpWidget(const SizedBox()); // dispose → cancels the poll timer
  });

  group('diagnostics (proposal 29)', () {
    Map<String, dynamic> diag({String state = 'Running', bool serving = true, bool mismatch = false, bool fcm = true, bool available = true}) => {
          'tailscale': {'available': available, 'state': state, 'dnsName': 'box.ts.net', 'serving': serving},
          'node': {'daemon': 'v18.20.8', 'shell': mismatch ? 'v20.20.2' : 'v18.20.8', 'mismatch': mismatch},
          'daemon': {'uptimeSec': 60, 'sdkVersion': '0.3.291', 'fcm': fcm},
        };

    test('old daemon without the block → null; new one parses', () {
      expect(SystemSnapshot.fromJson({}).diagnostics, isNull);
      final d = SystemSnapshot.fromJson({'diagnostics': diag()}).diagnostics!;
      expect(d.tailscaleState, 'Running');
      expect(d.sdkVersion, '0.3.291');
    });

    test('healthy → no hints', () {
      expect(diagnosticHints(Diagnostics.fromJson(diag())), isEmpty);
    });

    test('logged out wins over the (expected) missing serve mapping', () {
      final h = diagnosticHints(Diagnostics.fromJson(diag(state: 'NeedsLogin', serving: false)));
      expect(h, hasLength(1));
      expect(h.single, contains('sudo tailscale up'));
    });

    test('serve gone, node drift, push off, no tailscale CLI', () {
      expect(diagnosticHints(Diagnostics.fromJson(diag(serving: false))).single, contains('tailscale serve --bg 8787'));
      expect(diagnosticHints(Diagnostics.fromJson(diag(mismatch: true))).single, contains('v18.20.8 but a terminal picks v20.20.2'));
      expect(diagnosticHints(Diagnostics.fromJson(diag(fcm: false))).single, contains('Push is off'));
      expect(diagnosticHints(Diagnostics.fromJson(diag(available: false))).single, contains("Couldn't read Tailscale"));
    });
  });
}

// Daemon data + the server's own alert thresholds (ADR 0026).
void footprintTests() {
  group('daemon data footprint (ADR 0026)', () {
    test('an old daemon without the fields → empty footprint, default thresholds', () {
      final s = SystemSnapshot.fromJson({});
      expect(s.footprint, isEmpty);
      expect(s.diskAlertPercent, 90);
      expect(s.dataAlertGb, 0);
    });

    test('parses items, the truncation flag and the limits', () {
      final s = SystemSnapshot.fromJson({
        'footprint': [
          {'label': 'Claude transcripts', 'bytes': 1365729295},
          {'label': 'Session worktrees', 'bytes': 5, 'truncated': true},
        ],
        'limits': {'diskPercent': 80, 'dataAlertGb': 5},
      });
      expect(s.footprint.map((f) => f.label), ['Claude transcripts', 'Session worktrees']);
      expect(s.footprint[0].bytes, 1365729295);
      expect([s.footprint[0].truncated, s.footprint[1].truncated], [false, true]);
      expect([s.diskAlertPercent, s.dataAlertGb], [80, 5]);
    });

    testWidgets('the screen lists daemon data with a total, and flags a truncated count as a lower bound', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: SystemScreen(creds: const Creds('http://x', 't'), api: _FootprintApi()),
      ));
      await tester.pump();
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Daemon data'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Daemon data'), findsOneWidget);
      expect(find.text('Claude transcripts'), findsOneWidget);
      expect(find.textContaining('≥ '), findsOneWidget);
      expect(find.textContaining('alerts at 5 GB'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a disk meter turns "high" at the SERVER\'s threshold, not a fixed 90%', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 80% used: calm at the default 90, flagged when the server's threshold is 75.
      for (final (pct, expectHigh) in [(90, false), (75, true)]) {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark,
          home: SystemScreen(creds: const Creds('http://x', 't'), api: _FootprintApi(diskPercent: pct)),
        ));
        await tester.pump();
        await tester.pump();
        expect(find.textContaining('· high').evaluate().isNotEmpty, expectHigh, reason: 'threshold $pct%');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}

class _FootprintApi extends SystemApi {
  _FootprintApi({this.diskPercent = 90}) : super(Dio());
  final int diskPercent;
  @override
  Future<SystemSnapshot> snapshot() async => SystemSnapshot.fromJson({
        'hostname': 'snf',
        'uptimeSec': 1,
        'load': [0.1, 0.1, 0.1],
        'cpu': {'cores': 4, 'pct': 1.0},
        'mem': {'total': 100, 'available': 90, 'swapTotal': 0, 'swapFree': 0},
        'disks': [
          {'path': '/', 'total': 1000, 'free': 200}, // 80% used
        ],
        'footprint': [
          {'label': 'Claude transcripts', 'bytes': 1365729295},
          {'label': 'Daemon database', 'bytes': 28000000},
          {'label': 'Session worktrees', 'bytes': 99, 'truncated': true},
        ],
        'limits': {'diskPercent': diskPercent, 'dataAlertGb': 5},
        'alerts': [],
      });
}
