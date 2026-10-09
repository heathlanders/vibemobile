import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/data/fork_api.dart';
import 'package:vibemobile/features/chat/presentation/branch_sheet.dart';

void main() {
  group('ForkResult', () {
    test('a 201 parses into a Session and the copied count', () {
      final r = ForkResult.fromResponse(201, {
        'id': 's_new',
        'project_id': 'p',
        'kind': 'claude',
        'title': '↳ Original',
        'status': 'stale',
        'created_at': '2026-01-01T00:00:00Z',
        'copied': 4,
      });
      expect(r.ok, true);
      expect(r.session!.id, 's_new');
      expect(r.session!.title, '↳ Original');
      expect(r.session!.status, 'stale');
      expect(r.copied, 4);
    });

    test('failures carry the daemon\'s message, or a status fallback; a 201 without an id is a failure', () {
      expect(ForkResult.fromResponse(409, {'error': 'a turn is running'}).error, 'a turn is running');
      expect(ForkResult.fromResponse(409, {'error': 'a turn is running'}).ok, false);
      expect(ForkResult.fromResponse(500, null).error, contains('500'));
      expect(ForkResult.fromResponse(null, null).error, contains('0'));
      expect(ForkResult.fromResponse(201, {'nope': 1}).ok, false);
      expect(ForkResult.fromResponse(201, {'id': 7}).ok, false);
    });
  });

  group('ForkApi', () {
    test('POSTs {messageId, at} to the session\'s fork route', () async {
      final seen = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          seen.add(o);
          h.resolve(Response(requestOptions: o, statusCode: 201, data: {
            'id': 's2', 'project_id': 'p', 'kind': 'claude', 'status': 'stale', 'created_at': 't', 'copied': 2,
          }));
        }));
      final r = await ForkApi(dio).fork('s1', 'm9', at: 'before');
      expect(r.ok, true);
      expect(seen.single.method, 'POST');
      expect(seen.single.path, '/sessions/s1/fork');
      expect(seen.single.data, {'messageId': 'm9', 'at': 'before'});
    });
  });

  group('BranchSheet', () {
    Future<String?> pick(WidgetTester t, String tapText) async {
      String? got = 'unset';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(body: TextButton(onPressed: () async => got = await showBranchSheet(ctx), child: const Text('open'))),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text(tapText));
      await t.pumpAndSettle();
      return got;
    }

    testWidgets('offers both directions and says the original is left alone', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(body: TextButton(onPressed: () => showBranchSheet(ctx), child: const Text('open'))),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Keep this message and its reply'), findsOneWidget);
      expect(find.text('Branch before this message'), findsOneWidget);
      expect(find.textContaining('This chat is left as it is'), findsOneWidget);
    });

    testWidgets('choosing returns after / before', (t) async {
      expect(await pick(t, 'Keep this message and its reply'), 'after');
      await t.pumpWidget(const SizedBox());
      expect(await pick(t, 'Branch before this message'), 'before');
    });
  });
}
