import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/reconnect.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

// Proposal 70 C1: a turn sent while the socket is down must not be lost. Real
// controller against a real local WebSocket server that drops mid-session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ok(), isTrue);
  }

  test('send while disconnected: bubble stays queued, turn is delivered after reconnect', () async {
    final received = <Map<String, dynamic>>[];
    final sockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      // The daemon replays history first on every attach; it knows nothing of the queued turn.
      ws.add(jsonEncode({
        't': 'history',
        'messages': [
          {'role': 'user', 'content': 'earlier'},
        ],
      }));
      ws.listen((d) => received.add(jsonDecode(d as String) as Map<String, dynamic>));
    });
    addTearDown(() => server.close(force: true));

    final c = ChatSessionController(url: Uri.parse('ws://127.0.0.1:${server.port}/session/s1'), token: 't');
    addTearDown(c.dispose);
    c.start();
    await until(() => c.state == ConnState.live && c.messages.isNotEmpty);

    await sockets.first.close(1001); // network drop → retry
    await until(() => c.state == ConnState.reconnecting);

    c.sendUser('while down');
    final bubble = c.messages.last;
    expect(bubble.text, 'while down');
    expect(bubble.queued, isTrue, reason: 'shown as queued, not lost');

    await until(() => sockets.length == 2 && received.any((f) => f['t'] == 'user'));
    expect(received.where((f) => f['t'] == 'user').map((f) => f['text']), ['while down'], reason: 'delivered once');
    await until(() => c.messages.any((m) => m.text == 'while down'));
    final sent = c.messages.lastWhere((m) => m.role == ChatRole.user);
    expect(sent.text, 'while down', reason: 'the history replay did not erase it');
    expect(sent.queued, isFalse);
    expect(c.messages.map((m) => m.text), ['earlier', 'while down']);
  });

  test('retryNow skips the backoff wait (proposal 70 C10)', () async {
    var accepts = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      accepts++;
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({'t': 'history', 'messages': []}));
      if (accepts == 1) await ws.close(1001); // first attach drops at once → retry with backoff
    });
    addTearDown(() => server.close(force: true));
    final c = ChatSessionController(url: Uri.parse('ws://127.0.0.1:${server.port}/session/s1'), token: 't');
    addTearDown(c.dispose);
    c.start();
    await until(() => c.state == ConnState.reconnecting);
    // The first backoff is 0.4–0.6 s; retryNow must not wait for it.
    final sw = Stopwatch()..start();
    c.retryNow();
    await until(() => c.state == ConnState.live);
    expect(sw.elapsedMilliseconds, lessThan(300), reason: 'no backoff wait');
    expect(accepts, 2);
  });
}
