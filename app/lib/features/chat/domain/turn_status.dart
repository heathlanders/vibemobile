/// A running turn, from the daemon's `status` frames (proposal 32): what it's
/// doing, since when, and how long the model has been quiet. Times are anchored
/// to the local clock on receipt (the wire carries durations, not timestamps).
class TurnStatus {
  TurnStatus({required this.phase, this.tool, required this.startedAt, required this.idleMs, required this.receivedAt});

  factory TurnStatus.fromFrame(Map<String, dynamic> f, DateTime now) => TurnStatus(
        phase: f['phase'] as String? ?? 'thinking',
        tool: f['tool'] as String?,
        startedAt: now.subtract(Duration(milliseconds: (f['elapsedMs'] as num?)?.toInt() ?? 0)),
        idleMs: (f['idleMs'] as num?)?.toInt() ?? 0,
        receivedAt: now,
      );

  /// Optimistic local start (a sent turn, before the daemon's first frame).
  factory TurnStatus.local(DateTime now) =>
      TurnStatus(phase: 'thinking', startedAt: now, idleMs: 0, receivedAt: now);

  final String phase; // thinking | writing | tool | waiting
  final String? tool;
  final DateTime startedAt;
  final int idleMs; // model quiet time, as of [receivedAt]
  final DateTime receivedAt;

  /// The daemon heartbeats every 5 s mid-turn; silence past this = link or daemon gone.
  static const heartbeatGrace = Duration(seconds: 15);

  /// Model quiet this long while thinking/writing = probably stalled. Tool runs
  /// (a long build) and approval waits are legitimately quiet, so they're exempt.
  static const modelQuiet = Duration(seconds: 60);

  Duration elapsed(DateTime now) => now.difference(startedAt);

  /// Non-null when the turn looks stalled: how long nothing has happened.
  Duration? stalledFor(DateTime now) {
    final sinceFrame = now.difference(receivedAt);
    if (sinceFrame > heartbeatGrace) return sinceFrame;
    if (phase == 'tool' || phase == 'waiting') return null;
    final idle = Duration(milliseconds: idleMs) + sinceFrame;
    return idle > modelQuiet ? idle : null;
  }

  String get verb => switch (phase) {
        'writing' => 'Writing',
        'tool' => 'Running ${tool ?? 'tool'}',
        'waiting' => 'Waiting for approval',
        _ => 'Thinking',
      };

  /// e.g. "Running Bash… 1m 03s" or "Thinking… 12s · no activity 1m 10s".
  String label(DateTime now) {
    final stall = stalledFor(now);
    return '$verb… ${fmtDuration(elapsed(now))}${stall == null ? '' : ' · no activity ${fmtDuration(stall)}'}';
  }
}

/// 7s · 1m 03s · 1h 02m.
String fmtDuration(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
}
