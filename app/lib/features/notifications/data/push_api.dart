import 'package:dio/dio.dart';

/// REST client for the push surface (ADR 0013). Bearer-gated like every other
/// route; the [Dio] comes from `dioFor` (4xx returned, not thrown).
class PushApi {
  PushApi(this._dio);
  final Dio _dio;

  /// Register this device's FCM token so the daemon can wake it.
  Future<void> registerToken(String token) => _dio.post<void>('/devices/fcm', data: {'token': token});

  /// What a session is waiting on right now: `{title, permissions, dialogs}`.
  /// Null when the session is gone.
  Future<Map<String, dynamic>?> pending(String sessionId) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId/pending');
    return res.statusCode == 200 ? res.data : null;
  }

  /// Answer a permission request. Returns the HTTP status: 204 ok, 410 when the
  /// request already timed out or was answered elsewhere.
  Future<int?> answerPermission(String sessionId, String toolUseID, bool allow) async {
    final res = await _dio.post<void>('/sessions/$sessionId/permission', data: {'toolUseID': toolUseID, 'allow': allow});
    return res.statusCode;
  }

  /// Answer a question dialog. Same status contract as [answerPermission].
  Future<int?> answerDialog(String sessionId, String dialogId, Map<String, dynamic> result) async {
    final res = await _dio.post<void>(
      '/sessions/$sessionId/dialog',
      data: {'dialogId': dialogId, 'completed': true, 'result': result},
    );
    return res.statusCode;
  }
}
