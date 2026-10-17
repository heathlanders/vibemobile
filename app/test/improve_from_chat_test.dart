import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/prompts/presentation/improve_prompt.dart';

void main() {
  (String, String)? popped;

  Future<void> pump(WidgetTester t, {String draft = '', List<ChatMessage> messages = const []}) async {
    popped = null;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => popped = await showModalBottomSheet<(String, String)>(
            context: ctx,
            isScrollControlled: true,
            builder: (_) => ImproveSourceSheet(draft: draft, messages: messages),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  bool enabled(WidgetTester t, String label) =>
      t.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>())).enabled;

  testWidgets('lists sent and received messages only, newest first, and skips superseded turns', (t) async {
    await pump(t, messages: [
      ChatMessage(role: ChatRole.user, text: 'first ask'),
      ChatMessage(role: ChatRole.tool, text: 'tool noise', toolName: 'Bash'),
      ChatMessage(role: ChatRole.thinking, text: 'hmm'),
      ChatMessage(role: ChatRole.assistant, text: 'an answer'),
      ChatMessage(role: ChatRole.user, text: 'retried ask', superseded: true),
    ]);
    expect(find.text('first ask'), findsOneWidget);
    expect(find.text('an answer'), findsOneWidget);
    expect(find.text('tool noise'), findsNothing);
    expect(find.text('hmm'), findsNothing);
    expect(find.text('retried ask'), findsNothing);
    expect(t.getTopLeft(find.text('an answer')).dy, lessThan(t.getTopLeft(find.text('first ask')).dy));
  });

  testWidgets('empty box disables both actions; typing enables them and pops text + mode', (t) async {
    await pump(t);
    expect(enabled(t, 'Improve'), isFalse);
    expect(enabled(t, 'Go deeper'), isFalse);
    expect(find.text('Or start from a message'), findsNothing);
    await t.enterText(find.byType(TextField), 'fix the login bug');
    await t.pump();
    await t.tap(find.text('Go deeper'));
    await t.pumpAndSettle();
    expect(popped, ('fix the login bug', 'deeper'));
  });

  testWidgets('the draft is prefilled; tapping a message replaces the box text', (t) async {
    await pump(t, draft: 'my draft', messages: [ChatMessage(role: ChatRole.assistant, text: '  Claude said this  ')]);
    expect(find.widgetWithText(TextField, 'my draft'), findsOneWidget);
    await t.tap(find.text('Claude said this'));
    await t.pump();
    await t.tap(find.text('Improve'));
    await t.pumpAndSettle();
    expect(popped, ('Claude said this', 'improve'));
  });
}
