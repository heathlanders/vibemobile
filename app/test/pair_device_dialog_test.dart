import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/settings/data/admin_api.dart';
import 'package:vibemobile/features/settings/presentation/pair_device_dialog.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.expiresAt);
  final DateTime expiresAt;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future<void>? _) async {
    paths.add('${o.method} ${o.path}');
    return ResponseBody.fromString(
      jsonEncode({'code': '1234-5678', 'expires_at': expiresAt.toUtc().toIso8601String()}),
      201,
      headers: {'content-type': ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

const creds = Creds('https://box.tailnet.ts.net/', 't');

// Dio runs its stages on timers that need fake time, then real time for the
// (fake) I/O; drain both (same as desktop_shell_test.dart).
Future<void> _settleHttp(WidgetTester tester) async {
  for (var round = 0; round < 3; round++) {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
  await tester.pump(const Duration(milliseconds: 10));
}

Future<_Adapter> _open(WidgetTester tester, Duration ttl) async {
  final adapter = _Adapter(DateTime.now().add(ttl));
  final api = AdminApi(Dio(BaseOptions(baseUrl: creds.baseUrl))..httpClientAdapter = adapter);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: PairDeviceDialog(creds: creds, api: api)),
  ));
  await _settleHttp(tester);
  return adapter;
}

void main() {
  testWidgets('mints a code and shows it with the setup steps', (tester) async {
    final a = await _open(tester, const Duration(minutes: 10));
    expect(a.paths, ['POST /devices/pairing-code']);
    expect(find.text('1234-5678'), findsOneWidget);
    expect(find.textContaining('Single use'), findsOneWidget);
    expect(find.textContaining('irm https://box.tailnet.ts.net/dl/install.ps1 | iex'), findsOneWidget);
    expect(find.textContaining('enter https://box.tailnet.ts.net and the code'), findsOneWidget);
    expect(find.text('New code'), findsNothing);
  });

  testWidgets('an expired code offers a new one', (tester) async {
    final a = await _open(tester, const Duration(seconds: -1));
    expect(find.text('Expired'), findsOneWidget);
    await tester.tap(find.text('New code'));
    await _settleHttp(tester);
    expect(a.paths.length, 2);
  });
}
