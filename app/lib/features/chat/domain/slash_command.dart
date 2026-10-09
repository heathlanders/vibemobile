/// A Claude Code skill / project / plugin command the session can run as `/name args`
/// (daemon `commands` frame, proposal 41). Claude Code's own built-ins are not offered.
class SlashCommandInfo {
  const SlashCommandInfo({required this.name, this.description = '', this.hint = ''});
  final String name;
  final String description;

  /// Argument hint, e.g. `<file>`.
  final String hint;

  /// Type-safe: a malformed entry yields null instead of throwing out of the frame handler.
  static SlashCommandInfo? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    return SlashCommandInfo(
      name: name,
      description: j['description'] is String ? j['description'] as String : '',
      hint: j['hint'] is String ? j['hint'] as String : '',
    );
  }

  /// One line for the suggestion row, e.g. `<file> — Review the diff`.
  String get subtitle => [if (hint.isNotEmpty) hint, if (description.isNotEmpty) description].join(' — ');
}

/// Commands matching what is typed after the `/`: names that start with it first, then
/// names/descriptions that contain it. [exclude] hides names the app already handles
/// locally (`/prompt`, `/files`, …) so they never appear twice. Pure → tested.
List<SlashCommandInfo> matchCommands(
  List<SlashCommandInfo> all,
  String typed, {
  Set<String> exclude = const {},
  int limit = 8,
}) {
  final q = typed.trim().toLowerCase();
  final pool = [for (final c in all) if (!exclude.contains(c.name.toLowerCase())) c];
  final starts = <SlashCommandInfo>[];
  final contains = <SlashCommandInfo>[];
  for (final c in pool) {
    final name = c.name.toLowerCase();
    if (q.isEmpty || name.startsWith(q)) {
      starts.add(c);
    } else if (name.contains(q) || c.description.toLowerCase().contains(q)) {
      contains.add(c);
    }
  }
  return [...starts, ...contains].take(limit).toList();
}
