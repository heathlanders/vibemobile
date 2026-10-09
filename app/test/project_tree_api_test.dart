import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/data/project_tree_api.dart';

/// Canned-response adapter (same idiom as attachment_api_test).
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    lastOptions = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('tree() sends the query and maps relPaths', () async {
    final adapter = _FakeAdapter(200, {
      'root': '/home/user/vibemobile',
      'files': [
        {'relPath': 'lib/core/theme.dart'},
        {'relPath': 'lib/main.dart'},
      ],
      'truncated': false,
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://daemon'))..httpClientAdapter = adapter;

    final res = await ProjectTreeApi(dio).tree('s1', query: 'theme');

    expect(res.files, ['lib/core/theme.dart', 'lib/main.dart']);
    expect(res.truncated, false);
    expect(adapter.lastOptions!.path, '/sessions/s1/tree');
    expect(adapter.lastOptions!.queryParameters['q'], 'theme');
  });

  test('tree() surfaces the truncated flag', () async {
    final adapter = _FakeAdapter(200, {'root': '/r', 'files': [], 'truncated': true});
    final dio = Dio(BaseOptions(baseUrl: 'http://daemon'))..httpClientAdapter = adapter;

    final res = await ProjectTreeApi(dio).tree('s1');

    expect(res.truncated, true);
    expect(res.files, isEmpty);
  });
}
