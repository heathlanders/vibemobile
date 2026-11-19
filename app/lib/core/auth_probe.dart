import 'package:dio/dio.dart';

/// After a failed WS upgrade there is no close code to read. Ask the daemon with
/// the same token: only a 401/403 from an authenticated REST call means the token
/// is dead (proposal 70 C2). Never decided from exception text, which carries the
/// URL (hex session ids, ports) and can contain "401" by chance. Unreachable → false (retry).
Future<bool> tokenRejected(Uri wsUrl, String token) async {
  final url = wsUrl.replace(scheme: wsUrl.scheme == 'wss' ? 'https' : 'http', pathSegments: ['devices']);
  try {
    final res = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      validateStatus: (_) => true,
    )).getUri<Object>(url, options: Options(headers: {'authorization': 'Bearer $token'}));
    return res.statusCode == 401 || res.statusCode == 403;
  } catch (_) {
    return false;
  }
}
