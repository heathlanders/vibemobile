import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/data/rewind_api.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/chat/presentation/rewind_sheet.dart';

ChatSessionController controller() =>
    ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

/// Records every call; answers dry runs and real runs from the given results.
class FakeRewindApi extends RewindApi {
  FakeRewindApi({required this.dry, this.real}) : super(Dio());
  final RewindResult dry;
  final RewindResult? real;
  final calls = <bool>[]; // dryRun flags, in order

  @override
  Future<RewindResult> rewind(String sessionId, String messageId, {required bool dryRun}) async {
    calls.add(dryRun);
    return dryRun ? dry : real!;
  }
}

RewindResult ok({bool dryRun = true, List<String> files = const ['a.txt', 'lib/b.dart']}) =>
    RewindResult(statusCode: 200, canRewind: true, dryRun: dryRun, files: files, insertions: 1, deletions: 3);

void main() {
  group('message ids', () {
    test('history rows carry the daemon id onto the bubble', () {
      final c = controller();
      c.applyFrame({
        't': 'history',
        'messages': [
          {'id': 'm1', 'role': 'user', 'content': 'hi', 'ts': '2026-01-01'},
          {'id': 'm2', 'role': 'assistant', 'content': 'yo', 'ts': '2026-01-02'},
        ],
      });
      expect(c.messages.first.serverId, 'm1');
    });

    test('user_ack stamps the newest un-acked user bubble (FIFO), not older ones', () {
      final c = controller();
      c.applyFrame({
        't': 'history',
        'messages': [
          {'id': 'old', 'role': 'user', 'content': 'earlier', 'ts': '1'},
        ],
      });
      c.sendUser('first live');
      c.applyFrame({'t': 'user_ack', 'messageId': 'm-live'});
      expect(c.messages.last.text, 'first live');
      expect(c.messages.last.serverId, 'm-live');
      expect(c.messages.first.serverId, 'old', reason: 'an already-acked bubble is never overwritten');
    });

    test('user_ack with no pending bubble is ignored', () {
      final c = controller();
      c.applyFrame({'t': 'user_ack', 'messageId': 'x'});
      expect(c.messages, isEmpty);
    });

    test('serverId survives the offline transcript cache round-trip', () {
      final m = ChatMessage(role: ChatRole.user, text: 'hi', serverId: 'm1');
      expect(ChatMessage.fromJson(m.toJson()).serverId, 'm1');
      expect(ChatMessage(role: ChatRole.assistant, text: 'x').toJson().containsKey('serverId'), false);
    });
  });

  group('RewindResult', () {
    test('parses a 200 dry run', () {
      final r = RewindResult.fromResponse(200, {
        'canRewind': true,
        'dryRun': true,
        'filesChanged': ['a.txt'],
        'insertions': 2,
        'deletions': 1,
      });
      expect(r.canRewind, true);
      expect(r.files, ['a.txt']);
      expect(r.dryRun, true);
    });

    test('a 403 is never canRewind, even if the body says so', () {
      expect(RewindResult.fromResponse(403, {'canRewind': true, 'error': 'outside'}).canRewind, false);
    });

    test('error wording is distinct per status', () {
      String t(int s, [String? e]) => rewindErrorText(RewindResult.fromResponse(s, {'error': e}));
      expect(t(403), contains('outside the project'));
      expect(t(404), contains('no checkpoint'));
      expect(t(409, 'a turn is running'), 'a turn is running');
      expect(t(500), contains('500'));
    });
  });

  group('RewindSheet', () {
    Future<void> pump(WidgetTester tester, FakeRewindApi api) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: RewindSheet(api: api, sessionId: 's1', messageId: 'm1'))),
        );

    testWidgets('previews the files, warns about Bash, and does NOT rewind until tapped', (tester) async {
      final api = FakeRewindApi(dry: ok());
      await pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('lib/b.dart'), findsOneWidget);
      expect(find.textContaining('Bash'), findsOneWidget);
      expect(find.text('Rewind 2 files'), findsOneWidget);
      expect(api.calls, [true], reason: 'only the dry run so far');
    });

    testWidgets('tapping the button does the real rewind', (tester) async {
      final api = FakeRewindApi(dry: ok(), real: ok(dryRun: false));
      await pump(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rewind 2 files'));
      await tester.pumpAndSettle();
      expect(api.calls, [true, false]);
    });

    testWidgets('a refusal shows its reason and disables the button', (tester) async {
      final api = FakeRewindApi(dry: RewindResult.fromResponse(409, {'error': 'a turn is running — interrupt it first'}));
      await pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('a turn is running — interrupt it first'), findsOneWidget);
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNull);
    });

    testWidgets('nothing to undo → button disabled', (tester) async {
      final api = FakeRewindApi(dry: ok(files: const []));
      await pump(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('No tracked file changes to undo.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    });
  });
}
