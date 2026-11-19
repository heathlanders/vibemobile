import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/providers.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/pairing/presentation/pairing_screen.dart';

class _FakeStore extends TokenStore {
  _FakeStore();
  final saved = <(String, String)>[];

  @override
  Future<void> save(String baseUrl, String token) async => saved.add((baseUrl, token));
  @override
  Future<Creds?> read() async => null;
  @override
  Future<void> clear() async {}
}

// The screen calls the static AuthApi.pair (real Dio), so these tests talk to a
// real local server; tokenStoreProvider is faked (no secure-storage channel here).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // flutter_test answers every HTTP request 400

  late _FakeStore store;
  late int credsBuilds;
  final requests = <String>[];

  // Answers POST /pair with [status] + [body].
  Future<HttpServer> daemon(int status, Map<String, Object?> body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path} ${await utf8.decoder.bind(req).join()}');
      req.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  Future<void> pump(WidgetTester tester) async {
    store = _FakeStore();
    credsBuilds = 0;
    requests.clear();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        credsProvider.overrideWith((ref) {
          credsBuilds++;
          return null;
        }),
      ],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: Consumer(builder: (context, ref, _) {
          ref.watch(credsProvider);
          return const PairingScreen();
        }),
      ),
    ));
    await tester.pump();
  }

  // TextFields in order: daemon URL (dropdown), pairing code, device name.
  Future<void> fill(WidgetTester tester, {String? url, String code = '', String? name}) async {
    final fields = find.byType(TextField);
    if (url != null) await tester.enterText(fields.at(0), url);
    await tester.enterText(fields.at(1), code);
    if (name != null) await tester.enterText(fields.at(2), name);
  }

  Future<void> tapPair(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
      await Future<void>.delayed(const Duration(milliseconds: 300)); // real HTTP round trip
    });
    await tester.pump();
  }

  testWidgets('renders the form', (tester) async {
    await pump(tester);
    expect(find.text('Pair this device'), findsOneWidget);
    expect(find.text('Daemon URL'), findsOneWidget);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.text('Device name'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
  });

  testWidgets('empty code is rejected before any network call', (tester) async {
    final s = await tester.runAsync(() => daemon(201, {'token': 'tok'}));
    await pump(tester);
    await fill(tester, url: 'http://127.0.0.1:${s!.port}', code: '  ');
    await tapPair(tester);

    expect(find.text('All fields are required.'), findsOneWidget);
    expect(requests, isEmpty);
    expect(store.saved, isEmpty);
  });

  testWidgets('an http:// tailnet address is refused before any request (71 S4)', (tester) async {
    await pump(tester);
    await fill(tester, url: 'http://box.tailnet.ts.net:8088', code: 'AAAA-BBBB');
    await tapPair(tester);
    expect(find.text('Use the https:// address: pairing sends your device token.'), findsOneWidget);
    expect(store.saved, isEmpty);
  });

  testWidgets('a rejected code shows the server error and stores nothing', (tester) async {
    final s = await tester.runAsync(() => daemon(401, {'error': 'invalid or expired code'}));
    await pump(tester);
    await fill(tester, url: 'http://127.0.0.1:${s!.port}', code: 'BAD-CODE');
    await tapPair(tester);

    expect(requests, hasLength(1));
    expect(requests.single, startsWith('POST /pair '));
    expect(find.textContaining('invalid or expired code'), findsOneWidget);
    expect(store.saved, isEmpty);
    expect(credsBuilds, 1, reason: 'creds not invalidated on failure');
    // Button is usable again for a retry.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Pair')).onPressed, isNotNull);
  });

  testWidgets('an unreachable server shows an error and stores nothing', (tester) async {
    await pump(tester);
    await fill(tester, url: 'http://127.0.0.1:1', code: 'AAAA-BBBB');
    await tapPair(tester);

    expect(find.textContaining('DioException'), findsOneWidget); // raw text today; 70 C10 replaces it with a readable message
    expect(store.saved, isEmpty);
  });

  testWidgets('a good code stores the token and invalidates creds', (tester) async {
    final s = await tester.runAsync(() => daemon(201, {'token': 'device-token'}));
    await pump(tester);
    final url = 'http://127.0.0.1:${s!.port}';
    await fill(tester, url: url, code: ' 1234-5678 ', name: 'test-phone');
    await tapPair(tester);

    expect(jsonDecode(requests.single.split(' ').skip(2).join(' ')), {'code': '1234-5678', 'device_name': 'test-phone'});
    expect(store.saved, [(url, 'device-token')]);
    expect(credsBuilds, 2, reason: 'credsProvider re-read so the app root re-routes');
    expect(find.textContaining('Exception'), findsNothing);
  });
}
