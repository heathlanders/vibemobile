import 'package:dio/dio.dart';

import '../../sessions/domain/session.dart';

/// Result of `POST /sessions/:id/fork` (proposal 42). A failure carries the daemon's short,
/// generic message in [error].
class ForkResult {
  const ForkResult({required this.statusCode, this.session, this.copied, this.error});
  final int statusCode;
  final Session? session;

  /// How many history rows the new session started with.
  final int? copied;
  final String? error;
  bool get ok => statusCode == 201 && session != null;

  factory ForkResult.fromResponse(int? status, Map<String, dynamic>? j) {
    final code = status ?? 0;
    if (code != 201 || j == null || j['id'] is! String) {
      return ForkResult(statusCode: code, error: (j?['error'] as String?) ?? 'could not branch ($code)');
    }
    return ForkResult(statusCode: code, session: Session.fromJson(j), copied: (j['copied'] as num?)?.toInt());
  }
}

/// REST client for branching a conversation. 4xx passes through `validateStatus`.
class ForkApi {
  ForkApi(this._dio);
  final Dio _dio;

  /// [at] `after` keeps the chosen turn and its reply; `before` keeps only what precedes it.
  Future<ForkResult> fork(String sessionId, String messageId, {required String at}) async {
    final res = await _dio.post<Map<String, dynamic>>('/sessions/$sessionId/fork', data: {'messageId': messageId, 'at': at});
    return ForkResult.fromResponse(res.statusCode, res.data);
  }
}
