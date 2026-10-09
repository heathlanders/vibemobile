import 'package:dio/dio.dart';

/// Result of `POST /sessions/:id/rewind` (ADR 0023, session-rest.md).
/// [statusCode] is kept so the sheet can word 403/404/409 distinctly; a failed
/// call has [canRewind] false and [error] set.
class RewindResult {
  RewindResult({
    required this.statusCode,
    required this.canRewind,
    required this.dryRun,
    this.files = const [],
    this.insertions,
    this.deletions,
    this.skippedLinks,
    this.error,
  });

  final int statusCode;
  final bool canRewind;
  final bool dryRun;

  /// Project-relative paths the rewind changes (dry run) or changed (real run).
  final List<String> files;
  final int? insertions;
  final int? deletions;
  final int? skippedLinks;
  final String? error;

  factory RewindResult.fromResponse(int statusCode, Map<String, dynamic>? j) => RewindResult(
        statusCode: statusCode,
        canRewind: statusCode == 200 && j?['canRewind'] == true,
        dryRun: j?['dryRun'] != false,
        files: ((j?['filesChanged'] as List?) ?? const []).cast<String>(),
        insertions: (j?['insertions'] as num?)?.toInt(),
        deletions: (j?['deletions'] as num?)?.toInt(),
        skippedLinks: (j?['skippedLinks'] as num?)?.toInt(),
        error: j?['error'] as String?,
      );
}

/// REST client for file rewind. Bearer-gated via the configured Dio (`dioFor`);
/// 4xx passes through `validateStatus` so the caller branches on `statusCode`.
class RewindApi {
  RewindApi(this._dio);
  final Dio _dio;

  /// [dryRun] true previews; false really rewinds. The daemon dry-runs first
  /// either way and refuses out-of-project paths.
  Future<RewindResult> rewind(String sessionId, String messageId, {required bool dryRun}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/sessions/$sessionId/rewind',
      data: {'messageId': messageId, 'dryRun': dryRun},
    );
    return RewindResult.fromResponse(res.statusCode ?? 0, res.data);
  }
}
