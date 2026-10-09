import 'package:dio/dio.dart';

import '../domain/plan_usage.dart';

/// `GET /usage/plan` (ADR 0020) — the daemon's cached Max-plan meters.
class PlanUsageApi {
  PlanUsageApi(this._dio);
  final Dio _dio;

  Future<PlanUsage> fetch() async {
    final res = await _dio.get<Map<String, dynamic>>('/usage/plan');
    if (res.statusCode != 200 || res.data == null) throw Exception('could not load plan usage (${res.statusCode})');
    return PlanUsage.fromJson(res.data!);
  }
}
