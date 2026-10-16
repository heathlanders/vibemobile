import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/data/browse_api.dart';
import 'package:vibemobile/features/chat/presentation/file_browser_screen.dart';
import 'package:vibemobile/features/files/data/project_files_api.dart';

Dio stub(int status, Object? data, List<RequestOptions> seen, {bool throwIt = false}) => Dio(BaseOptions(validateStatus: (s) => s != null && s < 500))
  ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    seen.add(o);
    final r = Response(requestOptions: o, statusCode: status, data: data);
    throwIt ? h.reject(DioException.badResponse(statusCode: status, requestOptions: o, response: r)) : h.resolve(r);
  }));

UploadSource src(String name, [int len = 3]) => UploadSource(name: name, length: len, open: () => Stream.value(List.filled(len, 1)));

class UploadFake extends ProjectFilesApi {
  UploadFake() : super(Dio(), 'projects/p1');
  final calls = <(String, String, bool)>[];
  int existing = 1; // first N calls without overwrite answer 409

  @override
  Future<BrowseListing> list(String path) async => BrowseListing(path: path, entries: const []);

  @override
  Future<void> upload(String dir, UploadSource s, {bool overwrite = false, void Function(int, int)? onProgress}) async {
    calls.add((dir, s.name, overwrite));
    if (!overwrite && existing > 0) {
      existing--;
      throw BrowseError(409, 'exists');
    }
  }
}

void main() {
  group('ProjectFilesApi', () {
    test('list sends the scope and an encoded path; the root sends none', () async {
      final seen = <RequestOptions>[];
      final l = await ProjectFilesApi.project(stub(200, {'path': 'a/b', 'entries': []}, seen), 'p1').list('a/b');
      expect(l.path, 'a/b');
      expect(seen.single.path, '/projects/p1/files');
      expect(seen.single.uri.toString(), contains('path=a%2Fb'));
      final seen2 = <RequestOptions>[];
      await ProjectFilesApi.project(stub(200, {'entries': []}, seen2), 'p1').list('');
      expect(seen2.single.queryParameters, isEmpty);
    });

    test('readText maps the body', () async {
      final seen = <RequestOptions>[];
      final f = await ProjectFilesApi.session(stub(200, {'path': 'x.md', 'content': 'hi', 'size': 2, 'sha': 'abc'}, seen), 's1').readText('x.md');
      expect([f.content, f.size, f.truncated, seen.single.path], ['hi', 2, false, '/sessions/s1/files/text']);
    });

    test('upload PUTs the raw route with overwrite and octet-stream headers', () async {
      final seen = <RequestOptions>[];
      await ProjectFilesApi.session(stub(200, {'path': 'd/a.bin', 'sha': 'x', 'size': 3}, seen), 's1').upload('d', src('a.bin'), overwrite: true);
      final o = seen.single;
      expect([o.method, o.path], ['PUT', '/sessions/s1/files/raw']);
      expect(o.queryParameters, {'path': 'd/a.bin', 'overwrite': 1});
      expect(o.headers['content-type'], 'application/octet-stream');
      expect(o.headers['content-length'], 3);
      final seen2 = <RequestOptions>[];
      await ProjectFilesApi.session(stub(200, <String, dynamic>{}, seen2), 's1').upload('', src('a.bin'));
      expect(seen2.single.queryParameters, {'path': 'a.bin', 'overwrite': 0});
    });

    test('error bodies become BrowseError with the server message; 507 (a thrown DioException) too', () async {
      await expectLater(
        ProjectFilesApi.session(stub(409, {'error': 'already exists'}, []), 's').upload('', src('a')),
        throwsA(isA<BrowseError>().having((e) => e.status, 's', 409).having((e) => e.message, 'm', 'already exists')),
      );
      await expectLater(
        ProjectFilesApi.session(stub(507, {'error': 'The server disk is almost full'}, [], throwIt: true), 's').upload('', src('a')),
        throwsA(isA<BrowseError>().having((e) => e.status, 's', 507).having((e) => e.message, 'm', contains('disk'))),
      );
      await expectLater(ProjectFilesApi.session(stub(403, {'error': 'secret'}, []), 's').readText('.env'), throwsA(isA<BrowseError>().having((e) => e.status, 's', 403)));
    });

    test('download streams to the destination file', () async {
      final dir = Directory.systemTemp.createTempSync('pf');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dio = Dio()
        ..httpClientAdapter = _Bytes([1, 2, 3, 4]);
      final dest = File('${dir.path}/o.bin');
      final progress = <int>[];
      await ProjectFilesApi.project(dio, 'p1').download('a/o.bin', dest, onProgress: (r, t) => progress.add(r));
      expect(dest.readAsBytesSync(), [1, 2, 3, 4]);
    });
  });

  group('FileBrowserScreen transfers', () {
    testWidgets('a 409 asks to overwrite, then retries with overwrite true', (t) async {
      final api = UploadFake();
      await t.pumpWidget(MaterialApp(home: FileBrowserScreen(title: 'Proj', api: api, pickFiles: () async => [src('a.txt')])));
      await t.pumpAndSettle();
      expect(find.text('Proj'), findsOneWidget);
      await t.tap(find.byTooltip('Upload here'));
      await t.pumpAndSettle();
      expect(find.text('a.txt already exists. Overwrite?'), findsOneWidget);
      await t.tap(find.text('Overwrite'));
      await t.pumpAndSettle();
      expect(api.calls, [('', 'a.txt', false), ('', 'a.txt', true)]);
      expect(find.text('Uploaded'), findsOneWidget);
    });

    testWidgets('Skip does not retry', (t) async {
      final api = UploadFake();
      await t.pumpWidget(MaterialApp(home: FileBrowserScreen(title: 'Proj', api: api, pickFiles: () async => [src('a.txt')])));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Upload here'));
      await t.pumpAndSettle();
      await t.tap(find.text('Skip'));
      await t.pumpAndSettle();
      expect(api.calls.length, 1);
    });
  });
}

class _Bytes implements HttpClientAdapter {
  _Bytes(this.bytes);
  final List<int> bytes;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(bytes, 200, headers: {'content-length': ['${bytes.length}']});
  @override
  void close({bool force = false}) {}
}
