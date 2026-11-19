import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/reconnect.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

// Proposal 70 C5 + C6: the composer survives leaving the chat; a phone can type newlines.
void main() {
  const session = Session(id: 's1', projectId: 'p1', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');

  Future<ChatSessionController> pumpChat(WidgetTester tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return c;
  }

  testWidgets('a draft survives disposing and re-creating the chat screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpChat(tester);
    await tester.enterText(find.byType(TextField), 'half-written\nthought');
    await tester.pump(const Duration(seconds: 1)); // debounce
    await tester.pumpWidget(const SizedBox()); // leave the chat
    await tester.pump();

    await pumpChat(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'half-written\nthought');
  });

  testWidgets('an accepted send clears the stored draft', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = await pumpChat(tester);
    c.state = ConnState.live;
    await tester.enterText(find.byType(TextField), 'go');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Send'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    await pumpChat(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('the phone keyboard action inserts a newline instead of sending', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpChat(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.newline);
  });
}
