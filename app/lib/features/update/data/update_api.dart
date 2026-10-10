import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../domain/update_info.dart';

/// Static-file fetches from `https://<host>/dl/`. Plain Dio: the device token
/// must never be sent here.
class UpdateApi {
  UpdateApi([Dio? dio]) : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  final Dio _dio;

  Future<UpdateInfo?> latest(String serverBaseUrl) async {
    final res = await _dio.getUri<Object?>(
      latestJsonUrl(serverBaseUrl),
      options: Options(responseType: ResponseType.json, validateStatus: (s) => s != null && s < 500),
    );
    if (res.statusCode != 200) return null;
    return UpdateInfo.parse(res.data);
  }

  /// Downloads to [dest] and checks sha256; deletes the file and throws on mismatch.
  Future<void> download(Uri url, File dest, String sha256Hex, void Function(double) onProgress) async {
    await _dio.downloadUri(url, dest.path, onReceiveProgress: (r, t) {
      if (t > 0) onProgress(r / t);
    });
    final digest = await sha256.bind(dest.openRead()).first;
    if (digest.toString() != sha256Hex.toLowerCase()) {
      await dest.delete();
      throw Exception('checksum mismatch');
    }
  }
}
