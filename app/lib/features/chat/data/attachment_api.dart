import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Uploads images for a `kind=claude` turn (proposal 16, session-rest.md).
///
/// The daemon accepts the raw image bytes as the request body (NOT multipart) —
/// its content-type parser buffers them and sniffs the real media type from the
/// magic bytes, ignoring what we declare. So we send `application/octet-stream`
/// and trust the server-returned `mediaType`. The minted `attachmentId` then
/// rides the `user` WS frame's `images` (claude-ws.md).
class AttachmentApi {
  AttachmentApi(this._dio);
  final Dio _dio;

  /// POST raw [bytes] → the server-minted attachment id. Throws on rejection
  /// (oversize 413, unsupported type 415) — the caller surfaces it to the user.
  Future<String> upload(String sessionId, Uint8List bytes) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/sessions/$sessionId/attachments',
      data: Stream.fromIterable([bytes]),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: bytes.length},
      ),
    );
    if (res.statusCode != 201) {
      throw Exception('${(res.data?['error'] as String?) ?? 'upload failed'} (HTTP ${res.statusCode})');
    }
    return res.data!['attachmentId'] as String;
  }
}
