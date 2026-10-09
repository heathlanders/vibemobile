import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/domain/tool_groups.dart';

ChatMessage _tool(String name, {bool error = false}) =>
    ChatMessage(role: ChatRole.tool, toolName: name, toolResultIsError: error);
ChatMessage _text(ChatRole r) => ChatMessage(role: r, text: 'x');

void main() {
  test('consecutive tool calls fold into one run; other rows pass through', () {
    final u = _text(ChatRole.user);
    final a = _text(ChatRole.assistant);
    final rows = groupToolRuns([u, _tool('Read'), _tool('Bash'), a, _tool('Edit')]);
    expect(rows.length, 4);
    expect(rows[0], same(u));
    expect((rows[1] as ToolRun).calls.length, 2);
    expect(rows[2], same(a));
    expect((rows[3] as ToolRun).calls.length, 1);
  });

  test('summary counts names in first-seen order', () {
    final run = ToolRun([_tool('Read'), _tool('Bash'), _tool('Read'), _tool('Read')]);
    expect(run.summary, 'Read ×3 · Bash');
  });

  test('hasError reflects any failed call', () {
    expect(ToolRun([_tool('Read'), _tool('Bash', error: true)]).hasError, isTrue);
    expect(ToolRun([_tool('Read')]).hasError, isFalse);
  });

  test('no tools → no runs', () {
    expect(groupToolRuns([_text(ChatRole.user)]).whereType<ToolRun>(), isEmpty);
  });
}
