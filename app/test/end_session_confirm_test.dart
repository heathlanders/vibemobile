import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

// Proposal 70 C4: the close X ends the session on the server, so it asks first.
void main() {
  const session = Session(id: 's1', projectId: 'p1', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');

  testWidgets('closing a chat asks first; Cancel keeps the session', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    var closed = 0;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c, onClose: () => closed++),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byTooltip('Close session'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('End session?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(closed, 0, reason: 'cancel leaves the session running');

    await tester.tap(find.byTooltip('Close session'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'End'));
      await Future<void>.delayed(const Duration(milliseconds: 200)); // DELETE (stubbed) completes
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(closed, 1);
  });
}
