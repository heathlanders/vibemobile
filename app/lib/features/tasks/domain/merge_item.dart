/// Merge queue states (ADR 0032), in pipeline order.
const mergeStates = ['queued', 'rebasing', 'testing', 'awaiting_approval', 'merging', 'merged', 'bounced'];

/// Daemon cap on requeues of a bounced item (`attempt < 3`).
const maxMergeAttempts = 3;

/// The `result` of a queue item. Every key is optional; the daemon fills them in
/// as the item moves through the pipeline.
class MergeResult {
  const MergeResult({
    this.diffstat = '',
    this.commits = const [],
    this.untested = false,
    this.testOk,
    this.testExit,
    this.timedOut = false,
    this.output = '',
    this.reason,
    this.notes,
  });

  final String diffstat;
  final List<String> commits;

  /// No project test command was set: the item reached approval without a test run.
  final bool untested;
  final bool? testOk;
  final int? testExit;
  final bool timedOut;

  /// Last 64 KB of the test run, or the failed step's output on a bounce.
  final String output;
  final String? reason;
  final String? notes;

  factory MergeResult.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return MergeResult(
      diffstat: (j['diffstat'] as String?) ?? '',
      commits: ((j['commits'] as List<dynamic>?) ?? const []).map((c) => '$c').toList(),
      untested: j['untested'] == true,
      testOk: j['test_ok'] as bool?,
      testExit: (j['test_exit'] as num?)?.toInt(),
      timedOut: j['timed_out'] == true,
      output: (j['output'] as String?) ?? '',
      reason: j['reason'] as String?,
      notes: j['notes'] as String?,
    );
  }
}

/// One merge queue item (ADR 0032).
class MergeItem {
  const MergeItem({
    required this.id,
    required this.projectId,
    required this.taskId,
    this.sessionId,
    this.target = '',
    this.sourceSha,
    this.targetSha,
    this.testedSha,
    this.state = 'queued',
    this.attempt = 1,
    this.result = const MergeResult(),
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String projectId;
  final String taskId;
  final String? sessionId;
  final String target;
  final String? sourceSha;
  final String? targetSha;
  final String? testedSha;
  final String state;
  final int attempt;
  final MergeResult result;
  final String? createdAt;
  final String? updatedAt;

  bool get canRequeue => state == 'bounced' && attempt < maxMergeAttempts;

  factory MergeItem.fromJson(Map<String, dynamic> j) => MergeItem(
    id: j['id'] as String,
    projectId: (j['project_id'] as String?) ?? '',
    taskId: j['task_id'] as String,
    sessionId: j['session_id'] as String?,
    target: (j['target'] as String?) ?? '',
    sourceSha: j['source_sha'] as String?,
    targetSha: j['target_sha'] as String?,
    testedSha: j['tested_sha'] as String?,
    state: (j['state'] as String?) ?? 'queued',
    attempt: (j['attempt'] as num?)?.toInt() ?? 1,
    result: MergeResult.fromJson(j['result']),
    createdAt: j['created_at'] as String?,
    updatedAt: j['updated_at'] as String?,
  );
}

String shortSha(String? sha) => sha == null ? '?' : (sha.length <= 12 ? sha : sha.substring(0, 12));

/// The badge label for a queue state.
String mergeStateLabel(String state) => switch (state) {
  'awaiting_approval' => 'awaiting approval',
  _ => state,
};

/// Latest (by `created_at`, ties by list order = newest first) item per task.
/// The daemon returns newest first, so the first one seen wins.
Map<String, MergeItem> latestByTask(Iterable<MergeItem> items) {
  final out = <String, MergeItem>{};
  for (final i in items) {
    out.putIfAbsent(i.taskId, () => i);
  }
  return out;
}

/// The settings box as argv: split on whitespace, no shell parsing; empty = null.
List<String>? parseTestCommand(String text) {
  final parts = text.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? null : parts;
}

String testCommandText(List<String>? argv) => (argv ?? const []).join(' ');

/// Runners the daemon accepts as `argv[0]` (session-rest.md, Merge queue).
const allowedTestRunners = [
  'npm',
  'pnpm',
  'yarn',
  'node',
  'npx',
  'dart',
  'flutter',
  'cargo',
  'make',
  'pytest',
  'python3',
  'go',
];
