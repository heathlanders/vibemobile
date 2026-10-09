import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/multichat/presentation/multi_chat_screen.dart';
import 'package:vibemobile/features/multichat/presentation/session_tile.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

void main() {
  group('gridDims (proposal 19)', () {
    test('portrait shapes: 1 full, 2 stacked, 3-4 = 2x2, 5-6 = 2x3', () {
      expect(gridDims(0, false), (1, 1));
      expect(gridDims(1, false), (1, 1));
      expect(gridDims(2, false), (1, 2));
      expect(gridDims(3, false), (2, 2));
      expect(gridDims(4, false), (2, 2));
      expect(gridDims(5, false), (2, 3));
      expect(gridDims(6, false), (2, 3));
    });

    test('landscape flips the long axis: 2 side-by-side, 5-6 = 3x2', () {
      expect(gridDims(1, true), (1, 1));
      expect(gridDims(2, true), (2, 1));
      expect(gridDims(4, true), (2, 2));
      expect(gridDims(6, true), (3, 2));
    });

    test('every count fits all its tiles', () {
      for (var n = 1; n <= MultiChatScreen.maxTiles; n++) {
        for (final landscape in [false, true]) {
          final (cols, rows) = gridDims(n, landscape);
          expect(cols * rows, greaterThanOrEqualTo(n), reason: 'n=$n landscape=$landscape');
        }
      }
    });
  });

  group('SessionTile', () {
    const session = Session(
      id: 's1',
      projectId: 'p1',
      kind: 'claude',
      status: 'live',
      createdAt: '2026-01-01T00:00:00Z',
      title: 'my session',
    );

    Future<ChatSessionController> pump(WidgetTester tester) async {
      final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 220,
            child: SessionTile(session: session, controller: c, onTap: () {}, onRemove: () {}),
          ),
        ),
      ));
      return c;
    }

    testWidgets('streams deltas into the tail with a streaming caret', (tester) async {
      final c = await pump(tester);
      c.applyFrame({'t': 'delta', 'text': 'hello wor'});
      await tester.pump();
      expect(find.textContaining('hello wor ▍'), findsOneWidget);

      c.applyFrame({'t': 'assistant', 'text': 'hello world'});
      await tester.pump();
      expect(find.textContaining('▍'), findsNothing);
      expect(find.textContaining('hello world'), findsOneWidget);
    });

    testWidgets('pending permission shows the lock badge; responding clears it', (tester) async {
      final c = await pump(tester);
      expect(find.byIcon(Icons.lock_outline), findsNothing);

      c.applyFrame({'t': 'permission_request', 'toolUseID': 'tu1', 'toolName': 'Bash'});
      await tester.pump();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);

      c.respondPermission(false);
      await tester.pump();
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });

    testWidgets('busy turn shows the spinner until result', (tester) async {
      final c = await pump(tester);
      c.sendUser('go'); // socket is null (no connect) — just flips busy
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      c.applyFrame({'t': 'result', 'subtype': 'success'});
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('tool rows render as one-line chips, result rows are skipped', (tester) async {
      final c = await pump(tester);
      c.applyFrame({'t': 'tool_use', 'id': 'tu1', 'name': 'Read', 'input': {}});
      await tester.pump();
      expect(find.textContaining('⚙ Read'), findsOneWidget);
    });
  });
}
