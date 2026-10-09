import 'package:dio/dio.dart';

import '../../sessions/domain/session.dart';
import '../domain/scaffold.dart';

/// Raised when the daemon rejects a create/CRUD call (4xx). `dioFor` accepts
/// 4xx without throwing, so the API layer surfaces the daemon's `error` string.
class ProjectApiException implements Exception {
  ProjectApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// REST client for project creation + the scaffold library (proposal 17).
/// Bearer-gated; [Dio] is pre-configured with the token (dioFor, core/providers).
class ProjectApi {
  ProjectApi(this._dio);
  final Dio _dio;

  /// Create a new project dir under the server's project root, optionally
  /// seeding it from [scaffoldId] and running `git init` + commit. Returns the
  /// freshly catalogued [Project]; throws [ProjectApiException] on rejection.
  Future<Project> createProject({required String name, String? scaffoldId, bool git = true}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/projects',
      data: {'name': name, 'scaffold_id': ?scaffoldId, 'git': git},
    );
    if (res.statusCode == 201) return Project.fromJson(res.data!);
    throw ProjectApiException((res.data?['error'] ?? 'create failed').toString());
  }

  Future<List<ProjectScaffold>> listScaffolds() async {
    final res = await _dio.get<List<dynamic>>('/scaffolds');
    return (res.data ?? []).map((e) => ProjectScaffold.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ProjectScaffold> createScaffold({
    required String name,
    String? description,
    required List<ScaffoldFile> files,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/scaffolds', data: {
      'name': name,
      'description': ?description,
      'files': files.map((f) => f.toJson()).toList(),
    });
    if (res.statusCode == 201) return ProjectScaffold.fromJson(res.data!);
    throw ProjectApiException((res.data?['error'] ?? 'save failed').toString());
  }

  Future<ProjectScaffold> updateScaffold(String id, Map<String, dynamic> fields) async {
    final res = await _dio.put<Map<String, dynamic>>('/scaffolds/$id', data: fields);
    if (res.statusCode == 200) return ProjectScaffold.fromJson(res.data!);
    throw ProjectApiException((res.data?['error'] ?? 'save failed').toString());
  }

  Future<void> deleteScaffold(String id) => _dio.delete('/scaffolds/$id');
}
