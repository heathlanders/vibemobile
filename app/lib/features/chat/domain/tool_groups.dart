import 'chat_message.dart';

/// A consecutive run of tool calls, collapsed to one row in the chat so a busy
/// turn doesn't bury the conversation. Tapping the row reveals each call.
class ToolRun {
  ToolRun(this.calls);
  final List<ChatMessage> calls;

  /// Stable identity across rebuilds while the run grows at its tail.
  ChatMessage get first => calls.first;

  bool get hasError => calls.any((m) => m.toolResultIsError);

  /// "Read ×3 · Bash ×2" — names in first-seen order.
  String get summary {
    final counts = <String, int>{};
    for (final m in calls) {
      counts.update(m.toolName ?? 'tool', (n) => n + 1, ifAbsent: () => 1);
    }
    return counts.entries.map((e) => e.value > 1 ? '${e.key} ×${e.value}' : e.key).join(' · ');
  }
}

/// Fold [messages] into display rows: each [ChatMessage] passes through, and
/// every consecutive run of tool calls becomes one [ToolRun].
List<Object> groupToolRuns(List<ChatMessage> messages) {
  final rows = <Object>[];
  for (final m in messages) {
    if (m.role != ChatRole.tool) {
      rows.add(m);
    } else if (rows.isNotEmpty && rows.last is ToolRun) {
      (rows.last as ToolRun).calls.add(m);
    } else {
      rows.add(ToolRun([m]));
    }
  }
  return rows;
}
