import 'package:dio/dio.dart';

/// A paired device (`GET /devices`). [current] marks the device this app is
/// running on — revoking it signs the app out.
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.current,
    this.pairedAt,
    this.lastSeen,
  });

  final String id;
  final String name;
  final bool current;
  final String? pairedAt;
  final String? lastSeen;

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        current: j['current'] == true,
        pairedAt: j['paired_at'] as String?,
        lastSeen: j['last_seen'] as String?,
      );
}

/// One audit-log row (`GET /events`, security.md #14).
class AuditEvent {
  const AuditEvent({required this.id, required this.kind, required this.ts, this.deviceId, this.detail});

  final String id;
  final String kind;
  final String ts;
  final String? deviceId;
  final String? detail;

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        id: j['id'] as String,
        kind: j['kind'] as String,
        ts: j['ts'] as String,
        deviceId: j['device_id'] as String?,
        detail: j['detail'] as String?,
      );
}

/// Device management + audit log. Both are read-mostly admin surfaces; the log
/// has no mutating endpoint by design.
class AdminApi {
  AdminApi(this._dio);
  final Dio _dio;

  Future<List<PairedDevice>> devices() async {
    final res = await _dio.get<List<dynamic>>('/devices');
    return (res.data ?? []).map((e) => PairedDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> revoke(String deviceId) => _dio.delete('/devices/$deviceId');

  /// A single-use, 10-minute code for pairing another device (ADR 0029).
  Future<({String code, DateTime expiresAt})> pairingCode() async {
    final res = await _dio.post<Map<String, dynamic>>('/devices/pairing-code');
    final j = res.data!;
    return (code: j['code'] as String, expiresAt: DateTime.parse(j['expires_at'] as String));
  }

  Future<List<AuditEvent>> events({String? kind, String? before, int limit = 100}) async {
    final res = await _dio.get<List<dynamic>>('/events', queryParameters: {
      'limit': limit,
      'kind': ?kind,
      'before': ?before,
    });
    return (res.data ?? []).map((e) => AuditEvent.fromJson(e as Map<String, dynamic>)).toList();
  }
}
