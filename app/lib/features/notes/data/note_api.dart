import 'package:dio/dio.dart';

import '../domain/note.dart';

/// Project notes CRUD (proposal 31) — /projects/:id/notes, /notes/:id.
class NoteApi {
  NoteApi(this._dio);
  final Dio _dio;

  Future<List<Note>> list(String projectId) async {
    final res = await _dio.get<dynamic>('/projects/$projectId/notes'); // 4xx body is a map
    _check(res);
    return ((res.data as List<dynamic>?) ?? []).map((e) => Note.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Note> create(String projectId, String text) async {
    final res = await _dio.post<Map<String, dynamic>>('/projects/$projectId/notes', data: {'text': text});
    _check(res);
    return Note.fromJson(res.data!);
  }

  Future<Note> update(String id, {String? text, bool? done}) async {
    final res = await _dio.put<Map<String, dynamic>>('/notes/$id', data: {'text': ?text, 'done': ?done});
    _check(res);
    return Note.fromJson(res.data!);
  }

  Future<void> delete(String id) async => _check(await _dio.delete<void>('/notes/$id'));

  // dioFor doesn't throw on 4xx; surface them so the panel can revert.
  void _check(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      final data = res.data;
      throw Exception(data is Map && data['error'] != null ? data['error'] : 'HTTP $code');
    }
  }
}
