import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/ci_status.dart';
import 'package:vibemobile/features/chat/presentation/ci_sheet.dart';

Map<String, dynamic> withPr({String state = 'OPEN', bool draft = false, String? review, String? merge, List<Map<String, dynamic>>? checks, String checksState = 'passing'}) => {
      'available': true,
      'repo': 'octocat/vibemobile',
      'branch': 'feat/x',
      'pr': {'number': 14, 'title': 'Desktop client', 'state': state, 'url': 'https://github.com/o/r/pull/14', 'isDraft': draft, 'review': review, 'mergeState': merge},
      'checks': checks ?? [{'name': 'build', 'state': 'passing', 'url': 'https://github.com/o/r/runs/1'}],
      'checksState': checksState,
      'runs': [],
    };

void main() {
  group('CiStatus', () {
    test('a PR with checks parses; labels read naturally', () {
      final s = CiStatus.fromJson(withPr(review: 'APPROVED', merge: 'CLEAN'));
      expect(s.available, true);
      expect([s.repo, s.branch, s.pr!.number], ['octocat/vibemobile', 'feat/x', 14]);
      expect([s.pr!.stateLabel, s.pr!.reviewLabel, s.pr!.mergeLabel], ['Open', 'Approved', 'Ready to merge']);
      expect(s.checks.single.name, 'build');
    });

    test('Draft beats Open; merged/closed are capitalised; unknown review/merge states are silent', () {
      expect(CiStatus.fromJson(withPr(draft: true)).pr!.stateLabel, 'Draft');
      expect(CiStatus.fromJson(withPr(state: 'MERGED')).pr!.stateLabel, 'Merged');
      final p = CiStatus.fromJson(withPr(review: 'WEIRD', merge: 'UNKNOWN')).pr!;
      expect([p.reviewLabel, p.mergeLabel], [null, null]);
      expect(CiStatus.fromJson(withPr(review: 'CHANGES_REQUESTED', merge: 'DIRTY')).pr!.reviewLabel, 'Changes requested');
    });

    test('unavailable carries the daemon\'s reason; junk degrades, never throws', () {
      expect(CiStatus.fromJson({'available': false, 'reason': 'origin is not a GitHub repository'}).reason, 'origin is not a GitHub repository');
      for (final bad in [null, 5, 'x', [], <String, dynamic>{}]) {
        expect(CiStatus.fromJson(bad).available, false, reason: '$bad');
      }
      final odd = CiStatus.fromJson({'available': true, 'pr': {'number': 'x'}, 'checks': [null, 3, {'name': 5}, {'name': 'ok'}], 'runs': 'no'});
      expect([odd.pr, odd.checks.map((c) => c.name).toList(), odd.runs, odd.checksState], [null, ['ok'], isEmpty, 'none']);
    });
  });

  group('CiSheet', () {
    Future<List<String>> pump(WidgetTester t, Object? json, {bool fail = false}) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 700,
            child: CiSheet(
              load: () async => fail ? throw Exception('boom') : CiStatus.fromJson(json),
              open: (u) async => opened.add(u),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      return opened;
    }

    testWidgets('a PR: title, state, review, merge status and each check with its outcome', (t) async {
      await pump(t, withPr(review: 'APPROVED', merge: 'CLEAN', checks: [
        {'name': 'build', 'state': 'passing'},
        {'name': 'test', 'state': 'failing'},
        {'name': 'deploy', 'state': 'pending'},
        {'name': 'docs', 'state': 'skipped'},
      ]));
      expect(find.text('octocat/vibemobile · feat/x'), findsOneWidget);
      expect(find.text('#14 Desktop client'), findsOneWidget);
      expect(find.text('Open · Approved · Ready to merge'), findsOneWidget);
      expect(find.text('Checks'), findsOneWidget);
      for (final w in ['Passed', 'Failed', 'Running or waiting', 'Skipped']) {
        expect(find.text(w), findsOneWidget, reason: w);
      }
    });

    testWidgets('no PR: says so and lists the latest workflow runs instead', (t) async {
      await pump(t, {
        'available': true, 'repo': 'o/r', 'branch': 'main', 'pr': null, 'checks': [], 'checksState': 'failing',
        'runs': [{'name': 'CI', 'state': 'failing', 'url': 'https://github.com/o/r/actions/runs/1'}],
      });
      expect(find.text('No pull request for this branch.'), findsOneWidget);
      expect(find.text('Latest workflow runs'), findsOneWidget);
      expect(find.text('CI'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('empty states are plain', (t) async {
      await pump(t, withPr(checks: []));
      expect(find.text('No checks reported.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await pump(t, {'available': true, 'repo': 'o/r', 'branch': 'b', 'pr': null, 'checks': [], 'runs': []});
      expect(find.text('No runs for this branch.'), findsOneWidget);
    });

    testWidgets('unavailable shows the reason; a failed request shows a message, not a crash', (t) async {
      await pump(t, {'available': false, 'reason': 'the server is not signed in to GitHub (gh auth login)'});
      expect(find.textContaining('not signed in to GitHub'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await pump(t, null, fail: true);
      expect(find.textContaining('could not reach the server'), findsOneWidget);
    });

    testWidgets('tapping the PR or a check opens its https URL; a non-https URL is ignored', (t) async {
      final opened = await pump(t, withPr(checks: [
        {'name': 'build', 'state': 'passing', 'url': 'https://github.com/o/r/runs/1'},
        {'name': 'sneaky', 'state': 'passing', 'url': 'http://insecure.example/x'},
      ]));
      await t.tap(find.text('#14 Desktop client'));
      await t.tap(find.text('build'));
      await t.tap(find.text('sneaky'));
      await t.pump();
      expect(opened, ['https://github.com/o/r/pull/14', 'https://github.com/o/r/runs/1']);
    });
  });
}
