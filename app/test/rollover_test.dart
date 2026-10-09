import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/context_usage.dart';
import 'package:vibemobile/features/chat/domain/rollover.dart';
import 'package:vibemobile/features/chat/presentation/context_sheet.dart';

Map<String, dynamic> frame(int tokens, {int? autoAt = 1000, int max = 2000}) =>
    {'t': 'context', 'tokens': tokens, 'max': max, 'percent': 0, 'autoCompactAt': autoAt, 'categories': <dynamic>[], 'model': 'm'};

void main() {
  test('nudgeFresh turns on at 60% of the way to auto-compaction', () {
    expect(ContextUsage.fromFrame(frame(500)).nudgeFresh, isFalse);
    expect(ContextUsage.fromFrame(frame(600)).nudgeFresh, isTrue);
  });

  test('without a compaction point it falls back to the window', () {
    expect(ContextUsage.fromFrame(frame(1100, autoAt: null)).nudgeFresh, isFalse);
    expect(ContextUsage.fromFrame(frame(1300, autoAt: null)).nudgeFresh, isTrue);
  });

  test('the instructions name the standard files', () {
    expect(handoffInstruction, contains('docs/handoffs/'));
    expect(resumeInstruction, contains('docs/handoffs/'));
    expect(resumeInstruction, contains('PLAN.md'));
  });

  testWidgets('strip shows "Fresh session" only past the threshold and when wired', (t) async {
    var taps = 0;
    Widget host(int tokens, {bool wired = true}) => MaterialApp(
          home: Scaffold(
            body: ContextStrip(usage: ContextUsage.fromFrame(frame(tokens)), onTap: () {}, onFresh: wired ? () => taps++ : null),
          ),
        );
    await t.pumpWidget(host(100));
    expect(find.textContaining('Fresh session'), findsNothing);
    await t.pumpWidget(host(700, wired: false));
    expect(find.textContaining('Fresh session'), findsNothing);
    await t.pumpWidget(host(700));
    await t.tap(find.textContaining('Fresh session'));
    expect(taps, 1);
  });
}
