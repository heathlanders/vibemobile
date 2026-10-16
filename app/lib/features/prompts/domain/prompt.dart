import 'dart:convert';

/// A reusable prompt template. `body` may contain `{{var}}` placeholders;
/// `projectId == null` means a global prompt (reusable across all projects).
class Prompt {
  Prompt({
    required this.id,
    required this.title,
    required this.body,
    this.tags = const [],
    this.projectId,
    this.varsJson,
    this.useCount = 0,
    this.alwaysApply = false,
  });

  final String id;
  final String title;
  final String body;
  final List<String> tags;
  final String? projectId;
  final String? varsJson;

  /// Times used (ADR 0018) — the library's "most used" sort.
  final int useCount;

  /// Appended to the system prompt of every new session in scope (ADR 0031).
  final bool alwaysApply;

  bool get isGlobal => projectId == null;

  /// Defaults declared in `vars_json` (`{"name": "default", ...}`), if any.
  Map<String, String> get varDefaults {
    if (varsJson == null || varsJson!.isEmpty) return const {};
    try {
      final m = jsonDecode(varsJson!) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return const {};
    }
  }

  factory Prompt.fromJson(Map<String, dynamic> j) => Prompt(
        id: j['id'] as String,
        title: j['title'] as String,
        body: j['body'] as String,
        tags: (j['tags'] as String?)
                ?.split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList() ??
            const [],
        projectId: j['project_id'] as String?,
        varsJson: j['vars_json'] as String?,
        useCount: (j['use_count'] as num?)?.toInt() ?? 0,
        alwaysApply: j['always_apply'] == true,
      );
}

final RegExp _varPattern = RegExp(r'\{\{\s*([a-zA-Z0-9_]+)\s*\}\}');

/// The distinct `{{var}}` names in [body], in first-seen order.
List<String> extractVars(String body) {
  final seen = <String>[];
  for (final m in _varPattern.allMatches(body)) {
    final name = m.group(1)!;
    if (!seen.contains(name)) seen.add(name);
  }
  return seen;
}

/// Substitute `{{var}}` with [values]; a missing value leaves the placeholder
/// in place (so the user can see what wasn't filled).
String fillTemplate(String body, Map<String, String> values) =>
    body.replaceAllMapped(_varPattern, (m) => values[m.group(1)] ?? m.group(0)!);

/// A past user turn from any session (`GET /prompts/history`, ADR 0018).
/// Identical texts are collapsed; [times] counts them.
class PromptHistoryItem {
  const PromptHistoryItem({required this.text, required this.times, this.lastTs, this.project});
  final String text;
  final int times;
  final String? lastTs;
  final String? project;

  factory PromptHistoryItem.fromJson(Map<String, dynamic> j) => PromptHistoryItem(
        text: j['text'] as String,
        times: (j['times'] as num?)?.toInt() ?? 1,
        lastTs: j['last_ts'] as String?,
        project: j['project'] as String?,
      );
}

/// Session templates (proposal 04): prompts tagged `template` (any case). A
/// template starts a new Claude session with its filled body as the first turn.
const templateTag = 'template';
List<Prompt> templatesOf(Iterable<Prompt> prompts) =>
    prompts.where((p) => p.tags.any((t) => t.toLowerCase() == templateTag)).toList();
