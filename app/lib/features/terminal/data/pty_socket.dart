import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

/// Client for the PTY↔WS wire protocol (docs/protocols/pty-ws.md).
///
/// Uses [IOWebSocketChannel] specifically (not the cross-platform stub) so it can
/// (a) send the `Authorization: Bearer` header on the upgrade and (b) set a
/// `pingInterval` — dart:io auto-pings and closes the socket if no pong arrives,
/// which is the client-side drop detection that drives reconnect (reattach.md).
///
/// Frame layout, client→server: first byte is the ASCII opcode `'0'`/`'1'`
/// (0x30/0x31), rest is payload. Server→client: raw PTY bytes, verbatim.
class PtySocket {
  PtySocket._(this._channel);

  final IOWebSocketChannel _channel;

  static const int _opInput = 0x30; // '0' — keystroke
  static const int _opResize = 0x31; // '1' — resize {cols,rows}

  static Future<PtySocket> connect({
    required Uri url,
    required String token,
    Duration pingInterval = const Duration(seconds: 10),
  }) async {
    final channel = IOWebSocketChannel.connect(
      url,
      headers: {'authorization': 'Bearer $token'},
      pingInterval: pingInterval,
    );
    await channel.ready; // throws if the upgrade fails (e.g. 401)
    return PtySocket._(channel);
  }

  /// Raw PTY output decoded utf8. `allowMalformed` guards a multibyte char split
  /// across two frames (the stream is raw bytes, not char-aligned).
  Stream<String> get output => _channel.stream.map((event) {
        if (event is String) return event;
        return utf8.decode(event as List<int>, allowMalformed: true);
      });

  /// The WS close code once the stream is done — drives the reconnect policy
  /// (1000/4404 stop, 4401 re-auth, transient retry). Null until closed.
  int? get closeCode => _channel.closeCode;

  void sendInput(String data) => _send(_opInput, utf8.encode(data));

  void sendResize(int cols, int rows) =>
      _send(_opResize, utf8.encode(jsonEncode({'cols': cols, 'rows': rows})));

  void _send(int opcode, List<int> payload) {
    final frame = Uint8List(payload.length + 1)
      ..[0] = opcode
      ..setRange(1, payload.length + 1, payload);
    _channel.sink.add(frame);
  }

  Future<void> close() => _channel.sink.close();
}
