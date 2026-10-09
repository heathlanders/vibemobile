import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/usage/data/spend_api.dart';
import 'package:vibemobile/features/usage/domain/spend.dart';
import 'package:vibemobile/features/usage/presentation/session_spend_sheet.dart';
import 'package:vibemobile/features/usage/presentation/usage_screen.dart';
import 'package:dio/dio.dart';

SpendReport report(String group, List<Map<String, dynamic>> rows, Map<String, dynamic> totals) =>
    SpendReport.fromJson({'group': group, 'days': 30, 'totals': totals, 'rows': rows});

class _FakeApi extends SpendApi {
  _FakeApi() : super(Dio());
  @override
  Future<SpendReport> report({required String group, required int days}) async => switch (group) {
        'day' => SpendReport.fromJson({
            'group': 'day',
            'days': days,
            'totals': {'turns': 40, 'cost': 6.2},
            'rows': [
              for (var d = 1; d <= 14; d++) {'key': '2026-09-${d.toString().padLeft(2, '0')}', 'turns': d, 'cost': (d % 5 + 1) * 0.3},
            ],
          }),
        _ => SpendReport.fromJson({
            'group': group,
            'days': days,
            'totals': {'turns': 40, 'input': 20000, 'output': 30000, 'cacheRead': 900000, 'cacheWrite': 80000, 'cost': 6.2},
            'rows': [
              {'key': 'claude-opus-4-8', 'turns': 25, 'output': 5000, 'cacheRead': 800000, 'cost': 5.1},
              {'key': 'openai:gpt-5', 'turns': 10, 'output': 4000, 'cost': 0.9},
              {'key': 'claude-haiku-4-5', 'turns': 5, 'output': 1000, 'cost': 0.2},
            ],
          }),
      };
}

void main() {
  test('SpendReport parses; null sums become zero; cache hit rate', () {
    final r = report('model', [
      {'key': 'm', 'label': null, 'turns': 2, 'input': 10, 'output': 5, 'cacheRead': 30, 'cacheWrite': 0, 'cost': 0.5},
    ], {'turns': 2, 'input': 10, 'output': 5, 'cacheRead': 30, 'cacheWrite': null, 'cost': 0.5});
    expect(r.totals.cacheWrite, 0);
    expect(r.totals.cacheHitRate, 0.75);
    expect(r.rows.single.name, 'm');
    expect(SpendRow.fromJson({'key': '', 'label': null}).name, '(unknown)');
    expect(SpendRow.fromJson({'key': 'p1', 'label': 'alpha'}).name, 'alpha');
    expect(const SpendTotals().cacheHitRate, isNull);
  });

  group('savingsTips', () {
    test('too few turns → no tips', () {
      expect(savingsTips(report('model', [], {'turns': 3, 'input': 100, 'cost': 1})), isEmpty);
    });

    test('low cache reuse, cache churn, heavy context, pricey short turns', () {
      final tips = savingsTips(report('model', [
        {'key': 'big-model', 'turns': 20, 'output': 2000, 'cost': 4.0},
        {'key': 'cheap-model', 'turns': 20, 'output': 2000, 'cost': 0.2},
      ], {'turns': 40, 'input': 6000000, 'output': 4000, 'cacheRead': 100000, 'cacheWrite': 400000, 'cost': 4.2}));
      expect(tips.length, 4);
      expect(tips[0], contains('2% of input came from the prompt cache'));
      expect(tips[1], contains('written more than it is read'));
      expect(tips[2], contains('163k tokens of context'));
      expect(tips[3], contains('big-model'));
      expect(tips.join(), isNot(contains('cheap-model')));
    });

    test('CLAUDE.md over 40 KB in a project with enough turns → tip', () {
      final byModel = report('model', [], {'turns': 30, 'input': 3000, 'output': 30000, 'cacheRead': 900000, 'cost': 0.9});
      final byProject = report('project', [
        {'key': 'p1', 'label': 'alpha', 'turns': 20, 'claudeMdBytes': 52000},
        {'key': 'p2', 'label': 'beta', 'turns': 20, 'claudeMdBytes': 3000}, // small
        {'key': 'p3', 'label': 'gamma', 'turns': 3, 'claudeMdBytes': 90000}, // too few turns
        {'key': 'p4', 'label': 'delta', 'turns': 20}, // no CLAUDE.md
      ], {'turns': 63});
      final tips = savingsTips(byModel, byProject: byProject);
      expect(tips, hasLength(1));
      expect(tips.single, contains("alpha's CLAUDE.md is 52 KB (~13k tokens)"));
    });

    test('a healthy ledger yields nothing', () {
      expect(
        savingsTips(report('model', [
          {'key': 'm', 'turns': 30, 'output': 30000, 'cost': 0.9},
        ], {'turns': 30, 'input': 3000, 'output': 30000, 'cacheRead': 900000, 'cacheWrite': 20000, 'cost': 0.9})),
        isEmpty,
      );
    });
  });

  testWidgets('UsageScreen renders tiles, daily bars, breakdown and tips', (tester) async {
    await tester.binding.setSurfaceSize(Size(double.parse(Platform.environment['VIBE_W'] ?? '900'), 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: UsageScreen(creds: const Creds('http://x', 't'), api: _FakeApi()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('\$6.20'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget); // 900k / 1M cache hit
    expect(find.text('claude-opus-4-8'), findsOneWidget);
    expect(find.text('Saving tokens'), findsOneWidget);
    if (Platform.environment['VIBE_RENDER'] != null) {
      await expectLater(find.byType(UsageScreen), matchesGoldenFile(Platform.environment['VIBE_RENDER']!));
    }
  });

  testWidgets('session token sheet: totals, cache split and per-model rows', (tester) async {
    final r = SpendReport.fromJson({
      'group': 'model',
      'days': 0,
      'totals': {'turns': 4, 'input': 2000, 'output': 3000, 'cacheRead': 80000, 'cacheWrite': 18000, 'cost': 0.42},
      'rows': [
        {'key': 'claude-opus-4-8', 'turns': 3, 'input': 1500, 'cacheRead': 80000, 'cost': 0.4},
        {'key': 'claude-haiku-4-5', 'turns': 1, 'input': 500, 'cost': 0.02},
      ],
    });
    await tester.pumpWidget(MaterialApp(theme: AppTheme.dark, home: Scaffold(body: SessionSpendSheet(future: Future.value(r)))));
    await tester.pumpAndSettle();
    expect(find.text('Session tokens'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget); // 80k of 100k context from cache
    expect(find.text('claude-haiku-4-5'), findsOneWidget);
  });

  testWidgets('session token sheet: no turns yet', (tester) async {
    final r = SpendReport.fromJson({'group': 'model', 'days': 0, 'totals': {'turns': 0}, 'rows': []});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SessionSpendSheet(future: Future.value(r)))));
    await tester.pumpAndSettle();
    expect(find.textContaining('No completed turns'), findsOneWidget);
  });
}
