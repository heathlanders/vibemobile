import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

void main() {
  const session = Session(id: 's1', projectId: 'p1', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');
  final big = List.generate(30, (i) => 'row $i').join('\n');

  Future<ChatSessionController> pump(WidgetTester tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c),
      ),
    ));
    return c;
  }

  Future<void> tapChip(WidgetTester tester, Finder field) async {
    await tester.pump(); // lay out the token before hit-testing it
    await tester.tapAt(tester.getTopLeft(field) + const Offset(90, 24));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('large paste shows a token; tap opens the sheet; Expand inline restores the text', (tester) async {
    await pump(tester);
    final field = find.byType(TextField).last;
    await tester.enterText(field, big);
    final ctrl = tester.widget<TextField>(field).controller!;
    expect(ctrl.text, '[Pasted text #1 +30 lines]');

    await tapChip(tester, field);
    expect(find.text('Expand inline'), findsOneWidget);
    expect(find.text('Pasted text · 30 lines'), findsOneWidget);

    await tester.tap(find.text('Expand inline'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ctrl.text, big);
  });

  testWidgets('send expands the token; long user bubble is folded and can be opened', (tester) async {
    final c = await pump(tester);
    final field = find.byType(TextField).last;
    await tester.enterText(field, big);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(c.messages.any((m) => m.text == big), isTrue);
    expect(find.text('Show 24 more lines'), findsOneWidget);
    await tester.tap(find.text('Show 24 more lines'));
    await tester.pump();
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('Remove deletes the token', (tester) async {
    await pump(tester);
    final field = find.byType(TextField).last;
    await tester.enterText(field, big);
    await tapChip(tester, field);
    await tester.tap(find.text('Remove'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });
}
