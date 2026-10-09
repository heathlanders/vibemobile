import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

void main() {
  const session = Session(id: 's1', projectId: 'p1', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');

  testWidgets('onTitle reports the held title, then each auto-title rename once', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    c.applyFrame({'t': 'title', 'title': 'First'}); // already held (pooled controller)
    final seen = <String>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session, controller: c, onTitle: seen.add),
      ),
    ));
    await tester.pump();
    expect(seen, ['First']);

    c.applyFrame({'t': 'title', 'title': 'Renamed', 'auto': true});
    c.applyFrame({'t': 'title', 'title': 'Renamed'}); // reattach re-sends: no repeat
    await tester.pump();
    expect(seen, ['First', 'Renamed']);
  });
}
