import 'package:dio/dio.dart';

import '../domain/file_edits.dart';

/// REST client for the session file viewer (proposal 20, session-rest.md).
/// All routes are bearer-gated via the configured Dio (`dioFor`); 4xx passes
/// through `validateStatus` so callers branch on `statusCode`.
class FileEditsApi {
  FileEditsApi(this._dio);
  final Dio _dio;

  /// Changed-files list for the session. Empty list when nothing was edited.
  Future<List<ChangedFile>> changedFiles(String sessionId) async {
    final res = await _dio.get<List<dynamic>>('/sessions/$sessionId/file-edits');
    if (res.statusCode != 200) throw Exception('list failed (${res.statusCode})');
    return res.data!.map((e) => ChangedFile.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  /// Per-edit diff sections for one file.
  Future<FileDiff> diff(String sessionId, String path) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/sessions/$sessionId/file-edits/diff',
      queryParameters: {'path': path},
    );
    if (res.statusCode != 200) throw Exception('diff failed (${res.statusCode})');
    return FileDiff.fromJson(res.data!);
  }

  /// Current file content. Returns null when the file no longer exists (404)
  /// or isn't viewable (415 binary / 403 out of scope) — the caller renders the
  /// appropriate empty state.
  Future<FileContent?> content(String sessionId, String path) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/sessions/$sessionId/file',
      queryParameters: {'path': path},
    );
    if (res.statusCode != 200) return null;
    return FileContent.fromJson(res.data!);
  }
}
