/// A `/command` being typed in the composer, at the caret.
///
/// Pure logic so it can be unit-tested without a widget.
class SlashTrigger {
  const SlashTrigger({required this.query, required this.start, required this.end});

  /// Text typed after the `/`, e.g. `prompt review` for `/prompt review`.
  final String query;

  /// Index of the `/` in the composer text.
  final int start;

  /// Caret index (exclusive end of the trigger).
  final int end;

  /// First whitespace-separated word of [query] — the command name.
  String get command => query.split(' ').first;

  /// Everything after the command name, trimmed. '' when there is no argument.
  String get argument => query.contains(' ') ? query.substring(command.length + 1).trim() : '';
}

/// Detect a `/command` under the caret, or null.
///
/// The `/` must start a line so paths like `lib/core` and URLs never trigger.
SlashTrigger? detectSlash(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final before = text.substring(0, caret);
  final slash = before.lastIndexOf('/');
  if (slash < 0) return null;
  if (slash > 0 && before[slash - 1] != '\n') return null;
  final query = before.substring(slash + 1);
  if (query.contains('\n')) return null;
  return SlashTrigger(query: query, start: slash, end: caret);
}

/// An `@file` mention being typed in the composer, at the caret.
class MentionTrigger {
  const MentionTrigger({required this.query, required this.start, required this.end});

  /// Path fragment typed after the `@`, e.g. `lib/th` for `@lib/th`.
  final String query;

  /// Index of the `@` in the composer text.
  final int start;

  /// Caret index (exclusive end of the trigger).
  final int end;
}

/// Detect an `@path` mention under the caret, or null.
///
/// The `@` must start a word (start of text, or after whitespace) so emails and
/// `user@host` never trigger. Whitespace ends the mention.
MentionTrigger? detectMention(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final before = text.substring(0, caret);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  if (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1])) return null;
  final query = before.substring(at + 1);
  if (RegExp(r'\s').hasMatch(query)) return null;
  return MentionTrigger(query: query, start: at, end: caret);
}
