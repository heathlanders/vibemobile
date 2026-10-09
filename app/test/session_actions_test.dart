import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/sessions/data/session_api.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';
import 'package:vibemobile/features/sessions/presentation/session_actions.dart';

const _s = Session(id: 's1', projectId: 'p1', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');

/// Records calls; no HTTP (real Dio hangs inside the widget-test fake-async zone).
class _FakeApi implements SessionApi {
  final calls = <String>[];

  @override
  Future<WorktreeKept?> delete(String sessionId) async {
    calls.add('delete $sessionId');
    return null;
  }

  @override
  Future<Session> rename(String sessionId, String title) async {
    calls.add('rename $sessionId $title');
    return _s;
  }

  @override
  Future<Session> setTags(String sessionId, List<String> tags) async {
    calls.add('tags $sessionId ${tags.join('|')}');
    return _s;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  Future<(_FakeApi, BuildContext)> setup(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    return (_FakeApi(), ctx);
  }

  testWidgets('kill asks first; Cancel sends nothing, Kill deletes', (tester) async {
    final (api, ctx) = await setup(tester);

    var done = killSession(ctx, api, _s);
    await tester.pumpAndSettle();
    expect(find.text('Kill session?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await done, isFalse);
    expect(api.calls, isEmpty);

    done = killSession(ctx, api, _s);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kill'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    expect(api.calls, ['delete s1']);
  });

  testWidgets('rename sends the trimmed title; blank is a no-op', (tester) async {
    final (api, ctx) = await setup(tester);

    var done = renameSession(ctx, api, _s);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  New name  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    expect(api.calls, ['rename s1 New name']);

    done = renameSession(ctx, api, _s);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await done, isFalse);
    expect(api.calls, hasLength(1));
  });

  testWidgets('tags are split, trimmed, blanks dropped', (tester) async {
    final (api, ctx) = await setup(tester);

    final done = editSessionTags(ctx, api, _s);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' review, , bug ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await done, isTrue);
    expect(api.calls, ['tags s1 review|bug']);
  });
}
