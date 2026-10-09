import 'package:flutter/gestures.dart';
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

  // Tests run on the host (Linux) → isMobile is false → desktop composer keys.
  testWidgets('desktop composer: Enter sends, Shift+Enter does not', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(theme: AppTheme.dark, home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c)),
    ));

    final field = find.byType(TextField).last;
    await tester.enterText(field, 'hello');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, contains('hello'));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty); // sent → cleared
    expect(c.messages.any((m) => m.text == 'hello'), isTrue);
  });

  testWidgets('desktop composer: Tab inserts spaces at caret and keeps focus; mic button shown', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(theme: AppTheme.dark, home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c)),
    ));

    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);

    final field = find.byType(TextField).last;
    await tester.tap(field);
    await tester.enterText(field, 'ab');
    final ctrl = tester.widget<TextField>(field).controller!;
    ctrl.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, 'a  b');
    expect(ctrl.selection.baseOffset, 3);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('desktop chat: messages are selectable; right-click opens the actions menu', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(theme: AppTheme.dark, home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c)),
    ));
    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1)); // busy spinner never settles

    expect(find.byType(SelectionArea), findsOneWidget);
    await tester.tap(find.text('hello'), buttons: kSecondaryButton);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Copy message'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });
}
