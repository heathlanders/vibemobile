import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/providers.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/update/data/update_api.dart';
import 'package:vibemobile/features/update/domain/update_info.dart';
import 'package:vibemobile/features/update/presentation/update_banner.dart';
import 'package:vibemobile/features/update/presentation/update_controller.dart';

// What the update flow DECIDES (parsing/URLs are in update_test.dart). The
// controller picks its platform from dart:io, so on this Linux test host the
// real controller is "unsupported"; the dialog is driven through a fake one.

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body, {this.status = 200, this.type = 'application/octet-stream'});
  final List<int> body;
  final String type;
  final int status;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future<void>? _) async =>
      ResponseBody.fromBytes(body, status, headers: {'content-type': [type]});

  @override
  void close({bool force = false}) {}
}

UpdateApi _api(List<int> body, {int status = 200, String type = 'application/octet-stream'}) =>
    UpdateApi(Dio()..httpClientAdapter = _Adapter(body, status: status, type: type));

const _info = UpdateInfo(
  version: '9.9.9',
  build: 999,
  notes: 'shiny',
  apk: ReleaseFile('vibemobile-9.9.9.apk', 'abc'),
);

/// Controller whose state is seeded; install()/check() are recorded, not performed.
class _FakeController extends UpdateController {
  _FakeController(this.seed, {this.installError});
  final UpdateState seed;
  final String? installError;
  int installs = 0;
  int checks = 0;

  @override
  UpdateState build() => seed;

  @override
  Future<void> check({DateTime? now}) async {
    checks++;
    state = const UpdateState(info: _info);
  }

  @override
  Future<void> install() async {
    installs++;
    if (installError != null) state = state.copyWith(error: installError);
  }
}

void main() {
  group('UpdateApi', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('update_install_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    final payload = utf8.encode('pretend this is an apk');
    final goodSha = sha256.convert(payload).toString();
    final url = Uri.parse('https://box.tailnet.ts.net/dl/x.apk');

    test('a matching sha256 keeps the download (hash compare is case-insensitive)', () async {
      final dest = File('${tmp.path}/ok.apk');
      await _api(payload).download(url, dest, goodSha.toUpperCase(), (_) {});
      expect(dest.existsSync(), isTrue);
      expect(dest.readAsBytesSync(), payload);
    });

    test('a sha256 mismatch throws and deletes the file', () async {
      final dest = File('${tmp.path}/bad.apk');
      await expectLater(
        _api(payload).download(url, dest, 'deadbeef', (_) {}),
        throwsA(predicate((e) => '$e'.contains('checksum mismatch'))),
      );
      expect(dest.existsSync(), isFalse, reason: 'a tampered artifact must never be left to install');
    });

    test('a failed download (HTTP 404) throws and leaves nothing to install', () async {
      final dest = File('${tmp.path}/missing.apk');
      await expectLater(_api(utf8.encode('nope'), status: 404).download(url, dest, goodSha, (_) {}), throwsA(isA<DioException>()));
      expect(dest.existsSync(), isFalse);
    });

    test('latest() yields null for a non-200 feed and parses a 200 one', () async {
      expect(await _api(utf8.encode('{}'), status: 404, type: 'application/json').latest('https://box.tailnet.ts.net'), isNull);
      final j = jsonEncode({'version': '1.2.3', 'build': 5, 'apk': {'file': 'a.apk', 'sha256': 'AB'}});
      final info = await _api(utf8.encode(j), type: 'application/json').latest('https://box.tailnet.ts.net');
      expect(info!.build, 5);
      expect(info.isAvailable(4, 'android'), isTrue);
      expect(info.isAvailable(5, 'android'), isFalse, reason: 'same build is not an update');
    });
  });

  group('UpdateController (unsupported platform host)', () {
    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        credsProvider.overrideWith((ref) => const Creds('https://box.tailnet.ts.net', 't')),
        updateApiProvider.overrideWithValue(_api(utf8.encode('{}'))),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('starts with no update visible', () {
      expect(container().read(updateProvider).visible, isFalse);
    });

    test('checkNow reports the failure and shows nothing', () async {
      final c = container();
      expect(await c.read(updateProvider.notifier).checkNow(), startsWith('Update check failed'));
      expect(c.read(updateProvider).visible, isFalse);
    });

    test('install without a known update is a no-op (no progress, no error)', () async {
      final c = container();
      await c.read(updateProvider.notifier).install();
      final s = c.read(updateProvider);
      expect(s.progress, isNull);
      expect(s.error, isNull);
    });

    test('dismiss hides the update until a newer build', () {
      final c = ProviderContainer(overrides: [updateProvider.overrideWith(() => _FakeController(const UpdateState(info: _info)))]);
      addTearDown(c.dispose);
      expect(c.read(updateProvider).visible, isTrue);
      c.read(updateProvider.notifier).dismiss();
      expect(c.read(updateProvider).visible, isFalse);
      expect(c.read(updateProvider).dismissedBuild, 999);
    });
  });

  group('UpdateDialog / UpdateHost', () {
    Future<_FakeController> pumpDialog(WidgetTester tester, UpdateState seed, {String? installError}) async {
      final fake = _FakeController(seed, installError: installError);
      await tester.pumpWidget(ProviderScope(
        overrides: [updateProvider.overrideWith(() => fake)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const UpdateDialog()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 500));
      return fake;
    }

    testWidgets('shows the version, notes and Update now; tapping installs and closes', (tester) async {
      final fake = await pumpDialog(tester, const UpdateState(info: _info));
      expect(find.text('Update 9.9.9 available'), findsOneWidget);
      expect(find.textContaining('shiny'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Update now'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(fake.installs, 1);
      expect(find.byType(AlertDialog), findsNothing, reason: 'installer handed off, dialog closes');
    });

    testWidgets('an install error keeps the dialog open with the message and Retry', (tester) async {
      final fake = await pumpDialog(tester, const UpdateState(info: _info), installError: 'Update failed: checksum mismatch');
      await tester.tap(find.widgetWithText(FilledButton, 'Update now'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(fake.installs, 1);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Update failed: checksum mismatch'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    });

    testWidgets('while downloading there is no Later / install button', (tester) async {
      await pumpDialog(tester, const UpdateState(info: _info, progress: 0.4));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Later'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('manual-Windows state offers Download instead of installing', (tester) async {
      final fake = await pumpDialog(tester, const UpdateState(info: _info, manualWindows: true));
      expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      expect(fake.installs, 0);
    });

    testWidgets('Later dismisses the update', (tester) async {
      final fake = await pumpDialog(tester, const UpdateState(info: _info));
      await tester.tap(find.text('Later'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AlertDialog), findsNothing);
      expect(fake.state.visible, isFalse);
    });

    testWidgets('UpdateHost checks on launch and asks when a newer build is found', (tester) async {
      // _FakeController.check() always "finds" build 999: the dialog follows state.visible.
      final fake = _FakeController(const UpdateState());
      await tester.pumpWidget(ProviderScope(
        overrides: [updateProvider.overrideWith(() => fake)],
        child: MaterialApp(theme: AppTheme.dark, home: const UpdateHost(child: Scaffold(body: Text('shell')))),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(fake.checks, 1, reason: 'checks on launch');
      expect(find.text('Update 9.9.9 available'), findsOneWidget);

      await tester.tap(find.text('Later'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(AlertDialog), findsNothing);

      await tester.pumpWidget(const SizedBox()); // dispose: cancels the hourly timer
    });

    testWidgets('UpdateHost shows no dialog when nothing is newer', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          credsProvider.overrideWith((ref) => const Creds('https://box.tailnet.ts.net', 't')),
          updateApiProvider.overrideWithValue(_api(utf8.encode('{}'))),
        ],
        child: MaterialApp(theme: AppTheme.dark, home: const UpdateHost(child: Scaffold(body: Text('shell')))),
      ));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('shell'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
