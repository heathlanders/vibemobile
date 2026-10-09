import 'package:dio/dio.dart';

import '../domain/spend.dart';

/// `GET /spend` (ADR 0017): ledger aggregates grouped by model, project,
/// provider or day over the last [days].
class SpendApi {
  SpendApi(this._dio);
  final Dio _dio;

  Future<SpendReport> report({required String group, required int days}) async {
    final res = await _dio.get<Map<String, dynamic>>('/spend', queryParameters: {'group': group, 'days': days});
    final data = res.data;
    if (res.statusCode != 200 || data == null) {
      throw Exception((data?['error'] as String?) ?? 'could not load spend (${res.statusCode})');
    }
    return SpendReport.fromJson(data);
  }

  /// `GET /spend/session/:id`: one session's all-time totals, one row per model.
  Future<SpendReport> session(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/spend/session/${Uri.encodeComponent(id)}');
    final data = res.data;
    if (res.statusCode != 200 || data == null) {
      throw Exception((data?['error'] as String?) ?? 'could not load session spend (${res.statusCode})');
    }
    return SpendReport.fromJson({...data, 'group': 'model', 'days': 0});
  }
}
