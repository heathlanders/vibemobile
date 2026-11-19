import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/providers.dart';
import 'package:vibemobile/core/token_store.dart';

// Proposal 70 C3: one Dio per credentials, with timeouts, so a dead tailnet ends in
// an error state instead of an endless skeleton.
void main() {
  test('dioFor shares one Dio per credentials and sets timeouts', () {
    final a = dioFor(const Creds('https://box', 't1'));
    expect(identical(a, dioFor(const Creds('https://box', 't1'))), isTrue);
    expect(identical(a, dioFor(const Creds('https://box', 't2'))), isFalse, reason: 'a re-pair gets a fresh client');
    expect(a.options.connectTimeout, const Duration(seconds: 10));
    expect(a.options.receiveTimeout, const Duration(seconds: 30));
  });

  test('a black-hole host fails with a timeout instead of hanging', () async {
    // Accepts the TCP connection, never answers.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    server.listen(held.add);
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await server.close();
    });
    final dio = dioFor(Creds('http://127.0.0.1:${server.port}', 't'));
    final sw = Stopwatch()..start();
    await expectLater(
      dio.get<Object>('/projects', options: Options(receiveTimeout: const Duration(seconds: 1))),
      throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.receiveTimeout)),
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
