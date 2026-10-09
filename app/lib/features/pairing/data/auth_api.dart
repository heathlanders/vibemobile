import 'package:dio/dio.dart';

/// Pairing: redeem a one-time code (printed on the server by `npm run pair:new`)
/// for a long-lived device token. Uses the base URL but no token yet — `/pair`
/// is one of the daemon's two public routes (app.ts PUBLIC).
class AuthApi {
  static Future<String> pair({
    required String baseUrl,
    required String code,
    required String deviceName,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: baseUrl, validateStatus: (s) => s != null && s < 500));
    final res = await dio.post<Map<String, dynamic>>(
      '/pair',
      data: {'code': code, 'device_name': deviceName},
    );
    if (res.statusCode == 201 && res.data?['token'] is String) {
      return res.data!['token'] as String;
    }
    final msg = res.data?['error'] ?? 'pairing failed (${res.statusCode})';
    throw Exception(msg);
  }
}
