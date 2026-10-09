import 'package:dio/dio.dart';

import '../domain/schedule_info.dart';

class ScheduleRejected implements Exception {
  ScheduleRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// REST client for scheduled prompts (proposal 44). 4xx passes through `validateStatus`; the
/// daemon's short message becomes a [ScheduleRejected].
class ScheduleApi {
  ScheduleApi(this._dio);
  final Dio _dio;

  Future<SchedulesData> list() async {
    final res = await _dio.get<Map<String, dynamic>>('/schedules');
    if (res.statusCode != 200 || res.data == null) throw ScheduleRejected('could not load schedules (${res.statusCode})');
    final d = res.data!;
    return SchedulesData(
      tz: d['tz'] is String ? d['tz'] as String : '',
      offsetMin: d['offsetMin'] is num ? (d['offsetMin'] as num).toInt() : 0,
      schedules: [
        if (d['schedules'] is List)
          for (final s in d['schedules'] as List) ?ScheduleInfo.tryFromJson(s),
      ],
    );
  }

  Never _fail(Response<Map<String, dynamic>> res) =>
      throw ScheduleRejected((res.data?['error'] as String?) ?? 'request failed (${res.statusCode})');

  Future<ScheduleInfo> create(Map<String, Object?> body) async {
    final res = await _dio.post<Map<String, dynamic>>('/schedules', data: body);
    if (res.statusCode != 201) _fail(res);
    return ScheduleInfo.tryFromJson(res.data) ?? (throw ScheduleRejected('unexpected reply'));
  }

  Future<ScheduleInfo> update(String id, Map<String, Object?> body) async {
    final res = await _dio.patch<Map<String, dynamic>>('/schedules/$id', data: body);
    if (res.statusCode != 200) _fail(res);
    return ScheduleInfo.tryFromJson(res.data) ?? (throw ScheduleRejected('unexpected reply'));
  }

  Future<void> delete(String id) async {
    await _dio.delete<void>('/schedules/$id');
  }

  /// Run now; returns the new session's id.
  Future<String> runNow(String id) async {
    final res = await _dio.post<Map<String, dynamic>>('/schedules/$id/run');
    if (res.statusCode != 201 || res.data?['sessionId'] is! String) _fail(res);
    return res.data!['sessionId'] as String;
  }
}
