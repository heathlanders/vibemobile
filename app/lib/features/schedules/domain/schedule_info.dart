/// A scheduled prompt (`GET /schedules`, proposal 44). Times of day are in the SERVER's
/// local zone; [serverOffsetMin] converts instants for display and entry.
class ScheduleInfo {
  const ScheduleInfo({
    required this.id,
    required this.projectId,
    required this.title,
    required this.prompt,
    required this.mode,
    required this.kind,
    required this.enabled,
    this.projectName,
    this.model,
    this.time,
    this.days,
    this.runAt,
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastSessionId,
  });

  final String id, projectId, title, prompt, mode;
  final String? projectName, model;

  /// `daily` | `once`.
  final String kind;
  final bool enabled;

  /// `HH:MM` for a daily schedule.
  final String? time;

  /// 0-6 (Sunday = 0); null = every day.
  final List<int>? days;
  final DateTime? runAt, nextRunAt, lastRunAt;
  final String? lastStatus, lastSessionId;

  static ScheduleInfo? tryFromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['projectId'] is! String || j['title'] is! String) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    DateTime? d(String k) => j[k] is String ? DateTime.tryParse(j[k] as String)?.toUtc() : null;
    return ScheduleInfo(
      id: j['id'] as String,
      projectId: j['projectId'] as String,
      projectName: s('projectName'),
      title: j['title'] as String,
      prompt: s('prompt') ?? '',
      mode: s('mode') ?? 'ask',
      model: s('model'),
      kind: s('kind') ?? 'daily',
      time: s('time'),
      days: j['days'] is List ? [for (final x in j['days'] as List) if (x is num) x.toInt()] : null,
      runAt: d('runAt'),
      enabled: j['enabled'] == true,
      nextRunAt: d('nextRunAt'),
      lastRunAt: d('lastRunAt'),
      lastStatus: s('lastStatus'),
      lastSessionId: s('lastSessionId'),
    );
  }

  bool get isAuto => mode == 'auto';

  /// "Every day at 09:00" / "Mon–Fri at 09:00" / "Mon, Wed at 09:00" / "Once".
  String whenLabel(int serverOffsetMin) {
    if (kind == 'once') {
      final r = runAt;
      return r == null ? 'Once' : 'Once · ${formatServerTime(r, serverOffsetMin)}';
    }
    return '${daysLabel(days)} at ${time ?? '--:--'}';
  }

  /// A run that is waiting, skipped, missed or failed deserves the user's eye.
  bool get needsAttention {
    final s = lastStatus;
    return s != null && s != 'started';
  }
}

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

String daysLabel(List<int>? days) {
  if (days == null || days.length == 7) return 'Every day';
  final d = [...days]..sort();
  if (d.join(',') == '1,2,3,4,5') return 'Mon–Fri';
  if (d.join(',') == '0,6') return 'Weekends';
  return d.map((x) => _dayNames[x.clamp(0, 6)]).join(', ');
}

/// The server's wall clock for [instant] — the UTC fields shifted by the server's offset.
DateTime toServerLocal(DateTime instant, int offsetMin) => instant.toUtc().add(Duration(minutes: offsetMin));

/// The instant at which the server's wall clock reads [y-m-d h:min] — inverse of [toServerLocal].
DateTime fromServerLocal(int y, int m, int d, int h, int min, int offsetMin) =>
    DateTime.utc(y, m, d, h, min).subtract(Duration(minutes: offsetMin));

/// "Wed 7 Oct 09:00" in server time.
String formatServerTime(DateTime instant, int offsetMin) {
  final l = toServerLocal(instant, offsetMin);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_dayNames[l.weekday % 7]} ${l.day} ${months[l.month - 1]} ${two(l.hour)}:${two(l.minute)}';
}

class SchedulesData {
  const SchedulesData({required this.schedules, this.tz = '', this.offsetMin = 0});
  final List<ScheduleInfo> schedules;
  final String tz;
  final int offsetMin;
}
