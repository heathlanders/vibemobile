import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/domain/session_usage.dart';
import 'package:vibemobile/features/usage/data/plan_usage_api.dart';
import 'package:vibemobile/features/usage/domain/plan_usage.dart';
import 'package:vibemobile/features/usage/presentation/plan_usage_meter.dart';

class _FakeApi extends PlanUsageApi {
  _FakeApi(this.value) : super(Dio());
  final PlanUsage value;
  @override
  Future<PlanUsage> fetch() async => value;
}

void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

  test('windowElapsed: fraction of the window gone, from the reset time', () {
    expect(windowElapsed(now.add(const Duration(hours: 4)), sessionWindow, now), closeTo(0.2, 1e-9));
    expect(windowElapsed(now.add(const Duration(days: 7)), weeklyWindow, now), 0);
    expect(windowElapsed(now.subtract(const Duration(minutes: 1)), sessionWindow, now), 1); // clamped
    expect(windowElapsed(null, sessionWindow, now), isNull);
  });

  test('paceOf: under / on track / over the even-burn line, ±10 dead band', () {
    // Half the 5h window gone (resets in 2.5h) → even-burn line at 50%.
    final reset = now.add(const Duration(minutes: 150));
    UsageLimit l(double pct) => UsageLimit(label: 'Session', pct: pct, resetsAt: reset);
    expect(paceOf(l(20), sessionWindow, now), Pace.under);
    expect(paceOf(l(45), sessionWindow, now), Pace.onTrack);
    expect(paceOf(l(70), sessionWindow, now), Pace.over);
    expect(paceOf(const UsageLimit(label: 'x', pct: 5), sessionWindow, now), isNull);
  });

  test('PlanUsage.fromJson: null usage is kept null (never a fake 0%)', () {
    expect(PlanUsage.fromJson({'usage': null, 'fetchedAt': null}).usage, isNull);
    final p = PlanUsage.fromJson({
      'usage': {
        'session': {'label': 'Session', 'pct': 45, 'resetsAt': '2026-10-06T14:00:00Z'},
        'weekly': [
          {'label': 'All models', 'pct': 3, 'resetsAt': '2026-10-10T00:00:00Z'},
        ],
      },
      'fetchedAt': '2026-10-06T12:00:00Z',
    });
    expect(p.usage!.session!.pct, 45);
    expect(p.usage!.weekly.single.label, 'All models');
    expect(p.fetchedAt, DateTime.utc(2026, 10, 6, 12));
  });

  testWidgets('dense meter shows 5h + 7d; nothing when the daemon has no data', (tester) async {
    const creds = Creds('http://127.0.0.1:1', 't');
    final soon = DateTime.now().add(const Duration(hours: 2));
    final data = PlanUsage(
      usage: SessionUsage(
        session: UsageLimit(label: 'Session', pct: 45, resetsAt: soon),
        weekly: [
          UsageLimit(label: 'All models', pct: 12, resetsAt: soon),
          UsageLimit(label: 'Fable', pct: 3, resetsAt: soon),
        ],
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 72, child: PlanUsageMeter(creds: creds, api: _FakeApi(data)))),
    ));
    await tester.pump();
    expect(find.text('5h'), findsOneWidget);
    expect(find.text('45%'), findsOneWidget);
    expect(find.text('7d'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('3%'), findsNothing); // dense = all-models weekly only

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PlanUsageMeter(key: UniqueKey(), creds: creds, api: _FakeApi(const PlanUsage()))),
    ));
    await tester.pump();
    expect(find.text('5h'), findsNothing);
    await tester.pumpWidget(const SizedBox()); // dispose → poll timer cancelled
  });
}
