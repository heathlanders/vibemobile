/// Swarm task states (proposal 65), in board order.
const taskStates = ['ready', 'running', 'review', 'done'];

/// A project task (proposal 65): goal + scope (repo-relative path prefixes) + deps.
class Task {
  const Task({
    required this.id,
    required this.projectId,
    required this.title,
    this.body = '',
    this.scope = const [],
    this.deps = const [],
    this.state = 'ready',
    this.sessionId,
  });

  final String id;
  final String projectId;
  final String title;
  final String body;
  final List<String> scope;
  final List<String> deps;
  final String state;
  final String? sessionId;

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        projectId: j['project_id'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        scope: ((j['scope'] as List<dynamic>?) ?? const []).whereType<String>().toList(),
        deps: ((j['deps'] as List<dynamic>?) ?? const []).whereType<String>().toList(),
        state: (j['state'] as String?) ?? 'ready',
        sessionId: j['session_id'] as String?,
      );
}

/// The scope text box (one path per line) as a list: trimmed, blanks dropped, a
/// leading `./` removed, duplicates collapsed. The daemon validates the rest.
List<String> parseScope(String text) {
  final out = <String>[];
  for (final line in text.split('\n')) {
    var t = line.trim();
    while (t.startsWith('./')) {
      t = t.substring(2);
    }
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

String scopeText(List<String> scope) => scope.join('\n');

/// Tasks grouped by state in board order; empty groups are left out.
List<(String, List<Task>)> groupByState(Iterable<Task> tasks) => [
      for (final s in taskStates)
        if (tasks.any((t) => t.state == s)) (s, tasks.where((t) => t.state == s).toList()),
    ];
