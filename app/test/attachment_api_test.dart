import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/data/attachment_api.dart';

/// Canned-response adapter: records the last request and replays a fixed
/// status + JSON body, so we can assert what AttachmentApi puts on the wire.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;

  RequestOptions? lastOptions;
  final List<int> sentBytes = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        sentBytes.addAll(chunk);
      }
    }
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
  test('upload POSTs raw bytes and returns the minted id', () async {
    final adapter = _FakeAdapter(201, {'attachmentId': 'a_abc123', 'mediaType': 'image/png'});
    final dio = Dio(BaseOptions(baseUrl: 'http://daemon'))..httpClientAdapter = adapter;
    final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

    final id = await AttachmentApi(dio).upload('s1', bytes);

    expect(id, 'a_abc123');
    expect(adapter.lastOptions!.method, 'POST');
    expect(adapter.lastOptions!.path, '/sessions/s1/attachments');
    expect(adapter.sentBytes, bytes);
  });

  test('upload throws when the server rejects the image', () async {
    final adapter = _FakeAdapter(415, {'error': 'unsupported media type'});
    // Same validateStatus as dioFor: 4xx returns, so the API maps the body.
    final dio = Dio(BaseOptions(baseUrl: 'http://daemon', validateStatus: (s) => s != null && s < 500))
      ..httpClientAdapter = adapter;

    await expectLater(
      () => AttachmentApi(dio).upload('s1', Uint8List.fromList([0, 1, 2])),
      throwsA(predicate((e) => '$e'.contains('unsupported media type (HTTP 415)'))),
    );
  });
}
