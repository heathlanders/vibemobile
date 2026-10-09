import 'package:dio/dio.dart';

/// One row of a folder listing (`GET /sessions/:id/browse`, proposal 46). [readable] is false for
/// secret-looking files and links that leave the project: they are listed but never shown.
class BrowseEntry {
  const BrowseEntry({required this.name, required this.type, this.size, this.readable = true});
  final String name;

  /// `dir` | `file` | `link`.
  final String type;
  final int? size;
  final bool readable;
  bool get isDir => type == 'dir';

  static BrowseEntry? tryFromJson(Object? j) {
    if (j is! Map || j['name'] is! String || j['type'] is! String) return null;
    return BrowseEntry(
      name: j['name'] as String,
      type: j['type'] as String,
      size: j['size'] is num ? (j['size'] as num).toInt() : null,
      readable: j['readable'] != false,
    );
  }
}

class BrowseListing {
  const BrowseListing({required this.path, required this.entries, this.truncated = false});
  final String path;
  final List<BrowseEntry> entries;
  final bool truncated;
}

class BrowseFile {
  const BrowseFile({required this.path, required this.size, required this.content, this.truncated = false});
  final String path, content;
  final int size;
  final bool truncated;
}

/// A refusal from the daemon with its short, safe message. [status] 403 = not allowed (secret,
/// outside the project), 415 = binary, 404 = gone.
class BrowseError implements Exception {
  BrowseError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

/// "812 B" / "12 KB" / "1.4 MB".
String sizeLabel(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Read-only file browser for a session's checkout. 4xx passes through `validateStatus`.
class BrowseApi {
  BrowseApi(this._dio);
  final Dio _dio;

  Future<BrowseListing> list(String sessionId, String path) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId/browse', queryParameters: {if (path.isNotEmpty) 'path': path});
    if (res.statusCode != 200 || res.data == null) throw BrowseError(res.statusCode ?? 0, (res.data?['error'] as String?) ?? 'could not open the folder');
    final d = res.data!;
    return BrowseListing(
      path: d['path'] is String ? d['path'] as String : path,
      truncated: d['truncated'] == true,
      entries: [if (d['entries'] is List) for (final e in d['entries'] as List) ?BrowseEntry.tryFromJson(e)],
    );
  }

  Future<BrowseFile> read(String sessionId, String path) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId/browse/file', queryParameters: {'path': path});
    if (res.statusCode != 200 || res.data == null) throw BrowseError(res.statusCode ?? 0, (res.data?['error'] as String?) ?? 'could not open the file');
    final d = res.data!;
    return BrowseFile(
      path: d['path'] is String ? d['path'] as String : path,
      size: d['size'] is num ? (d['size'] as num).toInt() : 0,
      content: d['content'] is String ? d['content'] as String : '',
      truncated: d['truncated'] == true,
    );
  }
}
