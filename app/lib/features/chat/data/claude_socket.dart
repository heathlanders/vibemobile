import 'dart:convert';

import 'package:web_socket_channel/io.dart';

/// Client for the Claude session WS (docs/protocols/claude-ws.md) — JSON text
/// frames. Uses [IOWebSocketChannel] for the bearer header + pingInterval (same
/// drop-detection as the terminal's pty_socket.dart).
class ClaudeSocket {
  ClaudeSocket._(this._channel);

  final IOWebSocketChannel _channel;

  static Future<ClaudeSocket> connect({
    required Uri url,
    required String token,
    Duration pingInterval = const Duration(seconds: 10),
  }) async {
    final channel = IOWebSocketChannel.connect(
      url,
      headers: {'authorization': 'Bearer $token'},
      pingInterval: pingInterval,
    );
    await channel.ready; // throws on a failed upgrade (e.g. 401)
    return ClaudeSocket._(channel);
  }

  /// Decoded server frames (`{t: ...}`). See claude-ws.md for the frame table.
  Stream<Map<String, dynamic>> get frames => _channel.stream.map((event) {
        final s = event is String ? event : utf8.decode(event as List<int>);
        return jsonDecode(s) as Map<String, dynamic>;
      });

  int? get closeCode => _channel.closeCode;

  void sendUser(String text, {List<String> images = const []}) =>
      _send({'t': 'user', 'text': text, if (images.isNotEmpty) 'images': images});

  void sendPermission(String toolUseID, bool allow) =>
      _send({'t': 'permission', 'toolUseID': toolUseID, 'allow': allow});

  /// Switch the session mode (proposal 25). The daemon echoes a `mode` frame.
  void sendMode(String mode) => _send({'t': 'mode', 'mode': mode});

  /// Switch the model for the rest of the session (Claude engine only). The daemon
  /// answers with a `model` frame on success and silently ignores a refusal.
  void sendSetModel(String model) => _send({'t': 'set_model', 'model': model});

  /// Change reasoning effort (proposal 39); `null` = the model's default. The daemon
  /// answers with an `effort` frame on success and ignores a refusal.
  void sendSetEffort(String? level) => _send({'t': 'set_effort', 'effort': level});

  /// Ask for the session's MCP servers (proposal 43); the daemon answers with an `mcp` frame.
  void sendGetMcp() => _send({'t': 'get_mcp'});

  /// `reconnect` | `enable` | `disable` one MCP server of this session. The daemon only acts
  /// on a server it lists itself, then sends a fresh `mcp` frame.
  void sendMcpAction(String server, String action) => _send({'t': 'mcp_action', 'server': server, 'action': action});

  /// Compact the conversation now (proposal 40). The daemon refuses while a turn runs.
  void sendCompact() => _send({'t': 'compact'});

  /// Cancel the in-flight turn (proposal 09). The session stays live.
  void sendInterrupt() => _send({'t': 'interrupt'});

  /// Answer a `user_dialog` (AskUserQuestion). `completed:false` cancels it
  /// (the SDK then applies the dialog's default).
  void sendDialogResponse(String dialogId, {required bool completed, Object? result}) => _send({
        't': 'dialog_response',
        'dialogId': dialogId,
        'completed': completed,
        if (result != null) 'result': result,
      });

  void _send(Map<String, dynamic> frame) => _channel.sink.add(jsonEncode(frame));

  Future<void> close() => _channel.sink.close();
}
