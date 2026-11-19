import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/reconnect.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

// Proposal 70 C2: a failed upgrade clears the token only when an authenticated
// REST probe says so — never because the error text happens to contain "401"/"403".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // flutter_test answers every HTTP request 400; talk to the real local server

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ok(), isTrue);
  }

  // Refuses every WS upgrade with [upgradeStatus] + [body]; answers GET /devices with [probeStatus].
  Future<HttpServer> daemon({required int upgradeStatus, required String body, required int probeStatus}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final probe = req.uri.path == '/devices';
      req.response
        ..statusCode = probe ? probeStatus : upgradeStatus
        ..write(probe ? '[]' : body);
      req.response.close();
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  // Session ids are hex: one containing "4013" lands in the upgrade exception's URL text.
  Future<(ChatSessionController, List<int>)> start(HttpServer s) async {
    final c = ChatSessionController(url: Uri.parse('ws://127.0.0.1:${s.port}/session/s_c4013a'), token: 't');
    final authFailed = <int>[];
    c.onAuthFailed = () => authFailed.add(1);
    addTearDown(c.dispose);
    c.start();
    return (c, authFailed);
  }

  test('an upgrade error whose text contains "4013" does not clear the token', () async {
    final s = await daemon(upgradeStatus: 500, body: 'boom', probeStatus: 200);
    final (c, authFailed) = await start(s);
    await until(() => c.state == ConnState.reconnecting);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(authFailed, isEmpty);
    expect(c.state, isNot(ConnState.authFailed));
  });

  test('a 401 from the REST probe does', () async {
    final s = await daemon(upgradeStatus: 401, body: 'unauthorized', probeStatus: 401);
    final (c, authFailed) = await start(s);
    await until(() => c.state == ConnState.authFailed);
    expect(authFailed, [1]);
  });
}
