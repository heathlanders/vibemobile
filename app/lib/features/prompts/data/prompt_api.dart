import 'package:dio/dio.dart';

import '../domain/prompt.dart';

/// REST client for the prompt library (/prompts). Bearer-gated; [Dio] is
/// pre-configured with the token (dioFor, core/providers.dart).
class PromptApi {
  PromptApi(this._dio);
  final Dio _dio;

  /// All prompts, or — with [projectId] — globals + that project's.
  /// [mostUsed] sorts by use count (ADR 0018) instead of last edit.
  Future<List<Prompt>> list({String? projectId, bool mostUsed = false}) async {
    final res = await _dio.get<List<dynamic>>(
      '/prompts',
      queryParameters: {'project_id': ?projectId, if (mostUsed) 'sort': 'used'},
    );
    return (res.data ?? []).map((e) => Prompt.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Prompt> create({
    required String title,
    required String body,
    String? tags,
    String? projectId,
    String? varsJson,
    bool alwaysApply = false,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/prompts', data: {
      'title': title,
      'body': body,
      'tags': ?tags,
      'project_id': ?projectId,
      'vars_json': ?varsJson,
      if (alwaysApply) 'always_apply': true,
    });
    return Prompt.fromJson(res.data!);
  }

  Future<Prompt> update(String id, Map<String, dynamic> fields) async {
    final res = await _dio.put<Map<String, dynamic>>('/prompts/$id', data: fields);
    return Prompt.fromJson(res.data!);
  }

  Future<void> delete(String id) => _dio.delete('/prompts/$id');

  /// Count a use. Fire-and-forget at call sites — never blocks sending.
  Future<void> markUsed(String id) => _dio.post('/prompts/$id/use');

  /// Past user turns across all sessions, newest first, optionally filtered.
  Future<List<PromptHistoryItem>> history({String q = ''}) async {
    final res = await _dio.get<List<dynamic>>('/prompts/history', queryParameters: {if (q.isNotEmpty) 'q': q});
    return (res.data ?? []).map((e) => PromptHistoryItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Rewrite [text] against the prompting checklist (server-side model call).
  /// [mode] is 'improve' or 'deeper' ("Go deeper", proposal 61).
  Future<String> improve(String text, {String mode = 'improve'}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/prompts/improve',
      data: {'text': text, 'mode': mode},
      options: Options(receiveTimeout: const Duration(seconds: 90)),
    );
    final out = res.data?['text'];
    if (res.statusCode != 200 || out is! String) {
      throw Exception((res.data?['error'] as String?) ?? 'improve failed (${res.statusCode})');
    }
    return out;
  }
}
