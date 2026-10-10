// ADR 0029: "Pair a new device" from Settings → Paired devices.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/settings/data/admin_api.dart';
import 'package:vibemobile/features/settings/presentation/pair_device_dialog.dart';

import 'fakes.dart';
import 'harness.dart';

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future<void>? _) async => ResponseBody.fromString(
        jsonEncode({'code': '4821-0937', 'expires_at': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String()}),
        201,
        headers: {'content-type': ['application/json']},
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final size in [ShotSize.phone, ShotSize.desktop]) {
    testWidgets('pair device (${size.dir})', (tester) async {
      await startShot(tester, size);
      final api = AdminApi(Dio(BaseOptions(baseUrl: creds.baseUrl))..httpClientAdapter = _Adapter());
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: Scaffold(body: PairDeviceDialog(creds: creds, api: api)),
      ));
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      await tester.pump(const Duration(milliseconds: 10));
      await shot(tester, 'pair-device', size, 1, 'code');
      finishShot();
    });
  }
}
