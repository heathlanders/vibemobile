import 'package:dio/dio.dart';

/// One daemon setting (`GET /settings`, ADR 0026) with the limits the daemon will
/// enforce, so the UI can validate before it asks.
class ServerSetting {
  const ServerSetting({
    required this.key,
    required this.type,
    required this.value,
    required this.defaultValue,
    required this.isDefault,
    this.min,
    this.max,
    this.maxLen,
  });

  final String key;

  /// `bool` | `int` | `float` | `text`.
  final String type;
  final Object value;
  final Object defaultValue;
  final bool isDefault;
  final num? min;
  final num? max;
  final int? maxLen;

  factory ServerSetting.fromJson(Map<String, dynamic> j) => ServerSetting(
        key: j['key'] as String,
        type: j['type'] as String,
        value: j['value'] as Object,
        defaultValue: j['default'] as Object,
        isDefault: j['isDefault'] == true,
        min: j['min'] as num?,
        max: j['max'] as num?,
        maxLen: (j['maxLen'] as num?)?.toInt(),
      );
}

/// The daemon's settings as typed getters. Falls back to the daemon's own defaults
/// for a key an older daemon doesn't send.
class ServerSettings {
  ServerSettings(List<ServerSetting> all) : _byKey = {for (final s in all) s.key: s};
  final Map<String, ServerSetting> _byKey;

  ServerSetting? operator [](String key) => _byKey[key];

  bool get rulesEnabled => (_byKey['rules.enabled']?.value as bool?) ?? true;
  String get rulesText => (_byKey['rules.text']?.value as String?) ?? '';
  num get alertPercent => (_byKey['disk.alert_percent']?.value as num?) ?? 90;
  num get minFreeGb => (_byKey['disk.min_free_gb']?.value as num?) ?? 5;
  num get daemonDataAlertGb => (_byKey['disk.daemon_data_alert_gb']?.value as num?) ?? 5;
}

class SettingsRejected implements Exception {
  SettingsRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// REST client for daemon-wide settings. 4xx passes through `validateStatus`, so a
/// refused value surfaces as [SettingsRejected] carrying the daemon's message.
class ServerSettingsApi {
  ServerSettingsApi(this._dio);
  final Dio _dio;

  Future<ServerSettings> fetch() async {
    final res = await _dio.get<Map<String, dynamic>>('/settings');
    if (res.statusCode != 200) throw SettingsRejected('could not load settings (${res.statusCode})');
    return _parse(res.data);
  }

  /// Send [values]; a `null` value resets that key to its default. All-or-nothing.
  Future<ServerSettings> update(Map<String, Object?> values) async {
    final res = await _dio.put<Map<String, dynamic>>('/settings', data: {'values': values});
    if (res.statusCode != 200) {
      throw SettingsRejected((res.data?['error'] as String?) ?? 'could not save (${res.statusCode})');
    }
    return _parse(res.data);
  }

  ServerSettings _parse(Map<String, dynamic>? data) => ServerSettings([
        for (final e in (data?['settings'] as List? ?? const [])) ServerSetting.fromJson((e as Map).cast<String, dynamic>()),
      ]);
}
