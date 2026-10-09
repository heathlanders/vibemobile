import '../../chat/domain/session_usage.dart';

/// `GET /usage/plan` (ADR 0020): the Max-plan meters outside any chat. Reuses
/// the chat's [SessionUsage] shape — it's the same daemon cache.
class PlanUsage {
  const PlanUsage({this.usage, this.fetchedAt});

  /// Null until the daemon has fetched once (gateway mode, or the usage
  /// endpoint has only 429'd so far).
  final SessionUsage? usage;

  /// When the daemon last got a good answer; old = riding on a cached value.
  final DateTime? fetchedAt;

  factory PlanUsage.fromJson(Map<String, dynamic> j) => PlanUsage(
    usage: j['usage'] is Map ? SessionUsage.fromJson((j['usage'] as Map).cast<String, dynamic>()) : null,
    fetchedAt: DateTime.tryParse(j['fetchedAt'] as String? ?? ''),
  );
}

const sessionWindow = Duration(hours: 5);
const weeklyWindow = Duration(days: 7);

/// Fraction (0..1) of a rolling window already gone, from its reset time.
/// Null when the reset is unknown. Using the window evenly means usage tracks
/// this line; below it is capacity left on the table.
double? windowElapsed(DateTime? resetsAt, Duration window, DateTime now) {
  if (resetsAt == null) return null;
  final left = resetsAt.difference(now);
  return (1 - left.inSeconds / window.inSeconds).clamp(0.0, 1.0);
}

enum Pace { under, onTrack, over }

/// Usage vs. the even-burn line, with a ±10-point dead band so the hint
/// doesn't flap. Under = room to push harder before the reset.
Pace? paceOf(UsageLimit l, Duration window, DateTime now) {
  final e = windowElapsed(l.resetsAt, window, now);
  if (e == null) return null;
  final delta = l.pct - e * 100;
  if (delta < -10) return Pace.under;
  if (delta > 10) return Pace.over;
  return Pace.onTrack;
}

/// Compact countdown, e.g. "2h 54m", "3d 4h"; "" when unknown or past.
String fmtReset(DateTime? at, DateTime now) {
  if (at == null) return '';
  final d = at.difference(now);
  if (d.isNegative) return '';
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m';
}
