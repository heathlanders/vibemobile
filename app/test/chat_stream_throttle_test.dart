import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

// Proposal 70 C7: a burst of stream deltas must not rebuild the chat once per token.
void main() {
  testWidgets('300 back-to-back deltas notify a handful of times; the text is all there', (tester) async {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    var notified = 0;
    c.addListener(() => notified++);
    for (var i = 0; i < 300; i++) {
      c.applyFrame({'t': 'delta', 'text': 'x'});
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(notified, lessThanOrEqualTo(4), reason: '~30 Hz, not per token');
    expect(c.messages.single.text, 'x' * 300);

    notified = 0;
    final before = c.revision;
    c.applyFrame({'t': 'assistant', 'text': 'x' * 300});
    expect(notified, 1, reason: 'non-delta frames notify at once');
    expect(c.revision, before + 1, reason: 'the screen re-derives its rows');
  });
}
