import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/sessions/data/session_api.dart';

/// Replays a fixed status + JSON body so we can assert how SessionApi parses
/// the /models response.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );

  @override
  void close({bool force = false}) {}
}

SessionApi _apiWith(Map<String, dynamic> body) {
  final dio = Dio(BaseOptions(baseUrl: 'http://daemon'))..httpClientAdapter = _FakeAdapter(200, body);
  return SessionApi(dio);
}

void main() {
  test('models() drops entries with a missing id (stale-gateway crash guard)', () async {
    final models = await _apiWith({
      'models': [
        {'label': 'no-id-here'},
        {'id': 'gpt-4o', 'label': 'GPT-4o', 'provider': 'openai'},
      ],
    }).models();

    expect(models, hasLength(1));
    expect(models.single.id, 'gpt-4o');
    expect(models.single.label, 'GPT-4o');
  });

  test('models() falls back to id when label is missing', () async {
    final models = await _apiWith({
      'models': [
        {'id': 'default', 'provider': 'anthropic'},
      ],
    }).models();

    expect(models.single.label, 'default');
  });

  test('models() returns empty list when the array is absent', () async {
    final models = await _apiWith({'error': 'not found'}).models();
    expect(models, isEmpty);
  });
}
