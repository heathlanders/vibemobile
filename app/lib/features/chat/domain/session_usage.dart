/// Max-plan usage, pushed by the daemon as a `usage` frame (see vibe-daemon
/// usage.ts). On a subscription the real constraint is the rolling 5-hour session
/// window + weekly per-model limits — not a dollar cost. Absent for native
/// (pay-per-token) sessions, which keep the real `$` spend meter instead.
class UsageLimit {
  const UsageLimit({
    required this.label,
    required this.pct,
    this.resetsAt,
    this.severity,
  });

  /// "Session" | "All models" | a model display name (e.g. "Fable").
  final String label;

  /// Percent of the window consumed, 0..100.
  final double pct;

  final DateTime? resetsAt;

  /// "normal" | "warning" | ... — drives meter colour when not normal.
  final String? severity;

  factory UsageLimit.fromJson(Map<String, dynamic> j) => UsageLimit(
        label: j['label'] as String? ?? '',
        pct: (j['pct'] as num?)?.toDouble() ?? 0,
        resetsAt: DateTime.tryParse(j['resetsAt'] as String? ?? ''),
        severity: j['severity'] as String?,
      );
}

class SessionUsage {
  const SessionUsage({this.session, this.weekly = const []});

  final UsageLimit? session;
  final List<UsageLimit> weekly;

  factory SessionUsage.fromJson(Map<String, dynamic> j) => SessionUsage(
        session: j['session'] is Map
            ? UsageLimit.fromJson((j['session'] as Map).cast<String, dynamic>())
            : null,
        weekly: (j['weekly'] as List?)
                ?.whereType<Map>()
                .map((m) => UsageLimit.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
      );
}
