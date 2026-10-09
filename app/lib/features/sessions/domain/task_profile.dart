/// Per-task model profiles (ADR 0016 follow-up): the user maps each kind of work
/// to a model; a prompt that starts a session suggests its kind from keywords.
enum TaskKind {
  plan('Plan'),
  implement('Implement'),
  review('Review'),
  quick('Quick');

  const TaskKind(this.label);
  final String label;
}

RegExp _words(List<String> ws) => RegExp('\\b(${ws.join('|')})\\b', caseSensitive: false);

final _review = _words(['review', 'audit', 'critique', 'code review', 'pull request', 'pr', 'diff']);
final _plan = _words(['plan', 'design', 'architect', 'architecture', 'approach', 'proposal', 'spec', 'strategy', 'adr']);
final _quick = _words(['quick', 'quickly', 'explain', 'what is', 'what does', 'how do i', 'rename', 'typo']);
final _implement = _words(['implement', 'add', 'build', 'fix', 'refactor', 'write', 'create', 'migrate', 'update']);

/// The kind of work [prompt] reads as, or null when nothing matches. Checked
/// most-specific first: a "review the plan" prompt is a review. A short
/// question with no other signal counts as quick. Pure → unit-tested.
TaskKind? suggestTask(String prompt) {
  final t = prompt.trim();
  if (t.isEmpty) return null;
  if (_review.hasMatch(t)) return TaskKind.review;
  if (_plan.hasMatch(t)) return TaskKind.plan;
  if (_quick.hasMatch(t)) return TaskKind.quick;
  if (_implement.hasMatch(t)) return TaskKind.implement;
  if (t.length < 160 && t.endsWith('?')) return TaskKind.quick;
  return null;
}
