import 'package:dio/dio.dart';

import '../domain/ci_status.dart';

/// `GET /sessions/:id/ci` — read-only PR + CI status for the chat's branch.
class CiApi {
  CiApi(this._dio);
  final Dio _dio;

  Future<CiStatus> status(String sessionId) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId/ci');
    if (res.statusCode != 200) return CiStatus(available: false, reason: (res.data?['error'] as String?) ?? 'could not load (${res.statusCode})');
    return CiStatus.fromJson(res.data);
  }
}
