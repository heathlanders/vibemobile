import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

// Proposal 70 C11: a long tool result is cut in the list but can be read in full.
void main() {
  testWidgets('a truncated tool result offers its full output', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    final long = '${'x' * 3000}THE-END'; // over the 2,000-char cut, on one line so it fits the test viewport
    c.applyFrame({
      't': 'history',
      'messages': [
        {'role': 'tool', 'tool_json': '{"name":"Bash","input":{"command":"seq"},"id":"t1","result":${_json(long)}}'},
      ],
    });
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: ChatScreen(
          creds: const Creds('http://127.0.0.1:1', 't'),
          session: const Session(id: 's1', projectId: 'p', kind: 'claude', status: 'live', createdAt: 't'),
          controller: c,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    // Open the run ("1 tool call · Bash"), then the call's result tile (its "Bash" chip).
    await tester.tap(find.textContaining('tool call'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Bash'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('THE-END'), findsNothing, reason: 'cut in the list');
    // Pressed directly: the button sits in an animated, clipped tile inside the chat list.
    tester.widget<TextButton>(find.widgetWithText(TextButton, 'Show full output')).onPressed!();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    final full = tester.widget<SelectableText>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(SelectableText)));
    expect(full.data, long, reason: 'the whole result, untruncated');
  });
}

String _json(String s) => '"${s.replaceAll('\n', r'\n')}"';
