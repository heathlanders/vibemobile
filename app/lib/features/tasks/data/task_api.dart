import 'package:dio/dio.dart';

import '../domain/task.dart';

/// Swarm tasks (proposal 65) — /projects/:id/tasks, /tasks/:id[/dispatch].
class TaskApi {
  TaskApi(this._dio);
  final Dio _dio;

  Future<List<Task>> list(String projectId) async {
    final res = await _dio.get<dynamic>('/projects/$projectId/tasks'); // 4xx body is a map
    _check(res);
    return ((res.data as List<dynamic>?) ?? []).map((e) => Task.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Task> create(String projectId, {required String title, String body = '', List<String> scope = const [], List<String> deps = const []}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/projects/$projectId/tasks',
      data: {'title': title, 'body': body, 'scope': scope, 'deps': deps},
    );
    _check(res);
    return Task.fromJson(res.data!);
  }

  Future<Task> update(String id, {String? title, String? body, List<String>? scope, List<String>? deps, String? state}) async {
    final res = await _dio.put<Map<String, dynamic>>(
      '/tasks/$id',
      data: {'title': ?title, 'body': ?body, 'scope': ?scope, 'deps': ?deps, 'state': ?state},
    );
    _check(res);
    return Task.fromJson(res.data!);
  }

  Future<void> delete(String id) async => _check(await _dio.delete<void>('/tasks/$id'));

  /// Starts a worktree session on the task; returns the session id.
  Future<String> dispatch(String id) async {
    final res = await _dio.post<Map<String, dynamic>>('/tasks/$id/dispatch');
    _check(res);
    return res.data!['session_id'] as String;
  }

  // dioFor doesn't throw on 4xx; surface them (a 409 names the blocker).
  void _check(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      final data = res.data;
      throw Exception(data is Map && data['error'] != null ? data['error'] : 'HTTP $code');
    }
  }
}
