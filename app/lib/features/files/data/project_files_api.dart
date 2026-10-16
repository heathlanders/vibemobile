import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../chat/data/browse_api.dart';

/// Something to upload: a name, its byte length (the daemon wants Content-Length) and a way to
/// open its bytes as a stream, so a file is never held in memory.
class UploadSource {
  const UploadSource({required this.name, required this.length, required this.open});
  factory UploadSource.file(File f, {String? name}) =>
      UploadSource(name: name ?? f.uri.pathSegments.last, length: f.lengthSync(), open: f.openRead);
  final String name;
  final int length;
  final Stream<List<int>> Function() open;
}

/// A text file as the editor sees it (proposal 60): the content plus the `sha` a save must quote
/// as `baseSha` so the daemon can refuse to overwrite a change made since.
class TextDoc {
  const TextDoc({required this.path, required this.content, required this.sha, required this.mtime, required this.size});
  final String path, content, sha;
  final String? mtime;
  final int size;
}

/// What a save answered: the file's new hash, modification time and size.
class SaveResult {
  const SaveResult({required this.sha, required this.mtime, required this.size});
  final String sha;
  final String? mtime;
  final int size;
}

/// `409` on a save: the file changed since [baseSha] was read. [sha] is the daemon's current hash
/// (null when the 409 was "already exists" on create), so Overwrite can retry against it.
class StaleFileError extends BrowseError {
  StaleFileError(String message, this.sha) : super(409, message);
  final String? sha;
}

/// Proposal 59: list, read, download and upload files under a project (`projects/<id>`) or a
/// session's checkout (`sessions/<id>`). Refusals become [BrowseError] with the daemon's message.
class ProjectFilesApi {
  ProjectFilesApi(this._dio, this._scope);
  ProjectFilesApi.project(Dio dio, String id) : this(dio, 'projects/$id');
  ProjectFilesApi.session(Dio dio, String id) : this(dio, 'sessions/$id');
  final Dio _dio;
  final String _scope;

  /// `projects/<id>` or `sessions/<id>`: identifies the file tree this API reads.
  String get scope => _scope;

  Future<BrowseListing> list(String path) async {
    final res = await _guard(() => _dio.get<Map<String, dynamic>>('/$_scope/files', queryParameters: {if (path.isNotEmpty) 'path': path}));
    final d = _ok(res, 'could not open the folder');
    return BrowseListing(
      path: d['path'] is String ? d['path'] as String : path,
      truncated: d['truncated'] == true,
      entries: [if (d['entries'] is List) for (final e in d['entries'] as List) ?BrowseEntry.tryFromJson(e)],
    );
  }

  Future<TextDoc> readDoc(String path) async {
    final res = await _guard(() => _dio.get<Map<String, dynamic>>('/$_scope/files/text', queryParameters: {'path': path}));
    final d = _ok(res, 'could not open the file');
    return TextDoc(
      path: d['path'] is String ? d['path'] as String : path,
      content: d['content'] is String ? d['content'] as String : '',
      sha: d['sha'] is String ? d['sha'] as String : '',
      mtime: d['mtime'] is String ? d['mtime'] as String : null,
      size: d['size'] is num ? (d['size'] as num).toInt() : 0,
    );
  }

  /// Saves [content] over [path] (quote the [baseSha] it was read at) or, with [create], as a new
  /// file. A changed file throws [StaleFileError].
  Future<SaveResult> saveText(String path, String content, {String? baseSha, bool create = false}) async {
    final res = await _guard(() => _dio.put<Map<String, dynamic>>(
          '/$_scope/files/text',
          data: {'path': path, 'content': content, if (create) 'create': true else 'baseSha': baseSha},
        ));
    if (res.statusCode == 409) {
      final d = res.data;
      throw StaleFileError((d?['error'] as String?) ?? 'changed since you opened it', d?['sha'] is String ? d!['sha'] as String : null);
    }
    final d = _ok(res, 'could not save the file');
    return SaveResult(
      sha: d['sha'] is String ? d['sha'] as String : '',
      mtime: d['mtime'] is String ? d['mtime'] as String : null,
      size: d['size'] is num ? (d['size'] as num).toInt() : content.length,
    );
  }

  /// Streams the file to [dest]; a failed or refused download leaves nothing behind.
  Future<void> download(String path, File dest, {void Function(int received, int total)? onProgress}) async {
    try {
      await _dio.download(
        '/$_scope/files/raw',
        dest.path,
        queryParameters: {'path': path},
        options: Options(validateStatus: (s) => s == 200),
        onReceiveProgress: onProgress,
      );
    } on DioException catch (e) {
      if (dest.existsSync()) dest.deleteSync();
      throw await _fromDio(e, 'download failed');
    }
  }

  Future<void> upload(String dir, UploadSource src, {bool overwrite = false, void Function(int sent, int total)? onProgress}) async {
    final res = await _guard(() => _dio.put<Map<String, dynamic>>(
          '/$_scope/files/raw',
          queryParameters: {'path': dir.isEmpty ? src.name : '$dir/${src.name}', 'overwrite': overwrite ? 1 : 0},
          data: src.open(),
          options: Options(headers: {Headers.contentTypeHeader: 'application/octet-stream', Headers.contentLengthHeader: src.length}),
          onSendProgress: onProgress,
        ));
    _ok(res, 'upload failed');
  }

  Future<Response<Map<String, dynamic>>> _guard(Future<Response<Map<String, dynamic>>> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw await _fromDio(e, 'request failed');
    }
  }

  Map<String, dynamic> _ok(Response<Map<String, dynamic>> res, String fallback) {
    final s = res.statusCode ?? 0;
    if (s < 200 || s >= 300 || res.data == null) throw BrowseError(s, (res.data?['error'] as String?) ?? fallback);
    return res.data!;
  }

  Future<BrowseError> _fromDio(DioException e, String fallback) async {
    final r = e.response;
    if (r == null) return BrowseError(0, fallback);
    Object? data = r.data;
    if (data is ResponseBody) {
      try {
        data = jsonDecode(utf8.decode((await data.stream.toList()).expand((c) => c).toList()));
      } catch (_) {
        data = null;
      }
    }
    final msg = (data is Map && data['error'] is String) ? data['error'] as String : fallback;
    if (r.statusCode == 409 && data is Map && data['sha'] is String) return StaleFileError(msg, data['sha'] as String);
    return BrowseError(r.statusCode ?? 0, msg);
  }
}
