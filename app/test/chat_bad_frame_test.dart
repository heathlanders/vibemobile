import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/reconnect.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

// Proposal 70 C9: one malformed frame is skipped; the session keeps working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a frame with mistyped fields is skipped, later frames still apply', () {
    final c = ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
    addTearDown(c.dispose);
    expect(() => c.applyFrame({'t': 'assistant', 'text': 5}), returnsNormally);
    expect(() => c.applyFrame({'t': 'history', 'messages': 'nope'}), returnsNormally);
    expect(() => c.applyFrame({'t': 'tool_use', 'name': 1, 'input': 'x'}), returnsNormally);
    c.applyFrame({'t': 'assistant', 'text': 'fine'});
    expect(c.messages.last.text, 'fine');
  });

  test('a non-JSON or non-object frame on the wire does not drop the connection', () async {
    final sockets = <WebSocket>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.add(jsonEncode({'t': 'history', 'messages': []}));
      ws.add('not json');
      ws.add('[1,2]');
      ws.add(jsonEncode({'t': 'assistant', 'text': 'after'}));
    });
    addTearDown(() => server.close(force: true));
    final c = ChatSessionController(url: Uri.parse('ws://127.0.0.1:${server.port}/session/s1'), token: 't');
    addTearDown(c.dispose);
    c.start();
    for (var i = 0; i < 100 && !c.messages.any((m) => m.text == 'after'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(c.messages.any((m) => m.text == 'after'), isTrue);
    expect(c.state, ConnState.live);
    expect(sockets, hasLength(1), reason: 'no reconnect');
  });
}
