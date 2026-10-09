import 'package:dio/dio.dart';

import '../domain/system_snapshot.dart';

/// `GET /system` (ADR 0019) — read-only server health.
class SystemApi {
  SystemApi(this._dio);
  final Dio _dio;

  Future<SystemSnapshot> snapshot() async {
    final res = await _dio.get<Map<String, dynamic>>('/system');
    if (res.statusCode != 200 || res.data == null) throw Exception('could not load system status (${res.statusCode})');
    return SystemSnapshot.fromJson(res.data!);
  }
}
