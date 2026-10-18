import 'package:dio/dio.dart';

import '../domain/merge_item.dart';
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

  // Swarm merge queue (ADR 0032).

  Future<MergeItem> enqueue(String taskId) async {
    final res = await _dio.post<Map<String, dynamic>>('/tasks/$taskId/enqueue');
    _check(res);
    return MergeItem.fromJson(res.data!);
  }

  Future<List<MergeItem>> listQueue(String projectId) async {
    final res = await _dio.get<dynamic>('/projects/$projectId/merge-queue');
    _check(res);
    return ((res.data as List<dynamic>?) ?? []).map((e) => MergeItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// [sha] is the item's full `tested_sha`, as shown to the user.
  Future<MergeItem> approve(String itemId, String sha) async {
    final res = await _dio.post<Map<String, dynamic>>('/merge-queue/$itemId/approve', data: {'sha': sha});
    _check(res);
    return MergeItem.fromJson(res.data!);
  }

  Future<MergeItem> reject(String itemId) async {
    final res = await _dio.post<Map<String, dynamic>>('/merge-queue/$itemId/reject');
    _check(res);
    return MergeItem.fromJson(res.data!);
  }

  Future<MergeItem> requeue(String itemId) async {
    final res = await _dio.post<Map<String, dynamic>>('/merge-queue/$itemId/requeue');
    _check(res);
    return MergeItem.fromJson(res.data!);
  }

  /// The project's test command argv, or null when none is set.
  Future<List<String>?> getProjectSettings(String projectId) async {
    final res = await _dio.get<Map<String, dynamic>>('/projects/$projectId/settings');
    _check(res);
    return _argv(res.data?['test_command']);
  }

  Future<List<String>?> putProjectSettings(String projectId, {List<String>? testCommand}) async {
    final res = await _dio.put<Map<String, dynamic>>('/projects/$projectId/settings', data: {'test_command': testCommand});
    _check(res);
    return _argv(res.data?['test_command']);
  }

  static List<String>? _argv(Object? v) => v is List ? v.map((e) => '$e').toList() : null;

  // dioFor doesn't throw on 4xx; surface them (a 409 names the blocker).
  void _check(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      final data = res.data;
      throw Exception(data is Map && data['error'] != null ? data['error'] : 'HTTP $code');
    }
  }
}
