import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart' show ThinkingTile;
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

ChatSessionController controller() => ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

void main() {
  modelTests();
  test('thinking_delta grows ONE streaming thinking row; the final frame replaces it', () {
    final c = controller();
    c.applyFrame({'t': 'thinking_delta', 'text': 'Let me '});
    c.applyFrame({'t': 'thinking_delta', 'text': 'think'});
    expect(c.messages.length, 1);
    expect(c.messages.single.role, ChatRole.thinking);
    expect(c.messages.single.text, 'Let me think');
    expect(c.messages.single.streaming, true);

    c.applyFrame({'t': 'thinking', 'text': 'Let me think (summary)'});
    expect(c.messages.length, 1, reason: 'finalizes in place, no duplicate');
    expect(c.messages.single.text, 'Let me think (summary)');
    expect(c.messages.single.streaming, false);
  });

  test('the answer comes after its thinking row, as a separate bubble', () {
    final c = controller();
    c.applyFrame({'t': 'thinking_delta', 'text': 'hmm'});
    c.applyFrame({'t': 'delta', 'text': 'Ans'});
    c.applyFrame({'t': 'thinking', 'text': 'hmm'});
    c.applyFrame({'t': 'assistant', 'text': 'Answer'});
    expect(c.messages.map((m) => m.role), [ChatRole.thinking, ChatRole.assistant]);
    expect(c.messages.last.text, 'Answer');
  });

  test('a final thinking frame with no preceding deltas (late attach) still shows; an empty one does not', () {
    final c = controller();
    c.applyFrame({'t': 'thinking', 'text': 'late'});
    expect(c.messages.single.text, 'late');
    c.applyFrame({'t': 'thinking', 'text': ''});
    expect(c.messages.length, 1);
  });

  test('history replays thinking rows in order', () {
    final c = controller();
    c.applyFrame({
      't': 'history',
      'messages': [
        {'id': 'm1', 'role': 'user', 'content': 'q', 'ts': '1'},
        {'id': 'm2', 'role': 'thinking', 'content': 'reasoning', 'ts': '2'},
        {'id': 'm3', 'role': 'assistant', 'content': 'a', 'ts': '3'},
      ],
    });
    expect(c.messages.map((m) => m.role), [ChatRole.user, ChatRole.thinking, ChatRole.assistant]);
    expect(c.messages[1].text, 'reasoning');
  });

  test('a result ends any open thinking row so the next turn starts a fresh one', () {
    final c = controller();
    c.applyFrame({'t': 'thinking_delta', 'text': 'a'});
    c.applyFrame({'t': 'result', 'subtype': 'success'});
    c.applyFrame({'t': 'thinking_delta', 'text': 'b'});
    expect(c.messages.where((m) => m.role == ChatRole.thinking).length, 2);
  });

  test('thinking survives the offline cache round-trip', () {
    final m = ChatMessage(role: ChatRole.thinking, text: 'x');
    expect(ChatMessage.fromJson(m.toJson()).role, ChatRole.thinking);
  });

  testWidgets('ThinkingTile is collapsed by default and reveals the text on tap', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: ThinkingTile(text: 'secret reasoning', streaming: false))));
    expect(find.text('Thought'), findsOneWidget);
    expect(find.text('secret reasoning'), findsNothing);
    await t.tap(find.text('Thought'));
    await t.pumpAndSettle();
    expect(find.text('secret reasoning'), findsOneWidget);
  });

  testWidgets('ThinkingTile says Thinking… while streaming', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: ThinkingTile(text: '', streaming: true))));
    expect(find.text('Thinking…'), findsOneWidget);
  });
}

void modelTests() {
  test('a model frame sets the current model and enables switching', () {
    final c = controller();
    expect(c.canSwitchModel, false, reason: 'hidden until the daemon says so (native engine never sends it)');
    c.applyFrame({'t': 'model', 'model': 'claude-sonnet-5-5', 'canSwitch': true});
    expect(c.model, 'claude-sonnet-5-5');
    expect(c.canSwitchModel, true);
    c.applyFrame({'t': 'model', 'model': 'haiku', 'canSwitch': true});
    expect(c.model, 'haiku');
  });

  test('a model frame without canSwitch (or null model) does not enable the action', () {
    final c = controller();
    c.applyFrame({'t': 'model', 'model': null});
    expect(c.model, isNull);
    expect(c.canSwitchModel, false);
  });
}
