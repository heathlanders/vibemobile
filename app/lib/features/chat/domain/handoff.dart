import 'chat_message.dart';

/// "Hand off to…" (ADR 0016): the first turn of a new session on another model,
/// carrying this session's conversation. Keeps the most recent turns that fit in
/// [maxChars] (oldest dropped first) so a long session doesn't blow the target
/// model's context or the token budget. Tool calls appear as one-line markers;
/// tool output and result rows are left out. Pure → unit-tested.
String buildHandoffPrompt(List<ChatMessage> messages, {int maxChars = 12000}) {
  final lines = <String>[];
  for (final m in messages) {
    final line = switch (m.role) {
      ChatRole.user when m.text.isNotEmpty => 'User: ${m.text}',
      ChatRole.assistant when m.text.isNotEmpty => 'Assistant: ${m.text}',
      ChatRole.tool => '[tool: ${m.toolName ?? 'tool'}]',
      _ => null,
    };
    if (line != null) lines.add(line);
  }

  final kept = <String>[];
  var used = 0;
  for (final line in lines.reversed) {
    if (used + line.length > maxChars) break;
    kept.insert(0, line);
    used += line.length + 1;
  }
  final omitted = kept.length < lines.length;

  return [
    'You are taking over a coding session from another AI model, working in the same project directory.',
    'Here is the conversation so far${omitted ? ' (older turns omitted)' : ''}:',
    '',
    '<transcript>',
    ...kept,
    '</transcript>',
    '',
    'Continue the work from where it left off. Start by briefly stating your understanding '
        'of the current state and the next step, then proceed.',
  ].join('\n');
}
