import 'package:dio/dio.dart';

/// Result of `GET /sessions/:id/tree` — file **names** under the session's
/// project, never content (ADR 0010). [truncated] means the server capped the
/// walk or the match count; surface it, never imply full coverage.
class TreeResult {
  const TreeResult({required this.files, required this.truncated});

  final List<String> files; // project-relative paths
  final bool truncated;

  factory TreeResult.fromJson(Map<String, dynamic> j) => TreeResult(
        files: ((j['files'] as List?) ?? const [])
            .map((e) => (e as Map<String, dynamic>)['relPath'] as String)
            .toList(),
        truncated: j['truncated'] == true,
      );
}

/// REST client for the `@file` autocomplete surface. Bearer-gated via [Dio].
class ProjectTreeApi {
  ProjectTreeApi(this._dio);
  final Dio _dio;

  Future<TreeResult> tree(String sessionId, {String query = '', int limit = 20}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/sessions/$sessionId/tree',
      queryParameters: {'q': query, 'limit': limit},
    );
    return TreeResult.fromJson(res.data ?? const {});
  }
}
