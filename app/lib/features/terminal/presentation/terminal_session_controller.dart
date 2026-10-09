import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../../../core/reconnect.dart';
import '../data/pty_socket.dart';
import '../domain/ctrl_latch.dart';

/// Owns one terminal session's connection lifecycle: connect → attach → on drop,
/// apply the close-code policy (stop / re-auth / backoff+reconnect to the SAME
/// stable id). The [Terminal] persists across reconnects; tmux redraws scrollback
/// on each attach (reattach.md), so there's no client replay buffer.
class TerminalSessionController extends ChangeNotifier {
  TerminalSessionController({required this.url, required this.token});

  final Uri url;
  final String token;
  final Terminal terminal = Terminal(maxLines: 10000);

  /// Sticky Ctrl for the soft keyboard (terminal_key_row.dart).
  final CtrlLatch ctrl = CtrlLatch();

  /// Called when the session needs re-auth (4401 / 401 upgrade) — host clears the
  /// token and routes back to pairing.
  VoidCallback? onAuthFailed;

  ConnState state = ConnState.connecting;
  String? error;

  PtySocket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _disposed = false;
  bool _stopped = false;

  void start() {
    terminal.onOutput = (data) => _socket?.sendInput(ctrl.take(data));
    terminal.onResize = (cols, rows, _, _) => _socket?.sendResize(cols, rows);
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed || _stopped) return;
    _set(_attempt == 0 ? ConnState.connecting : ConnState.reconnecting);
    try {
      final socket = await PtySocket.connect(url: url, token: token);
      _socket = socket;
      _attempt = 0;
      _set(ConnState.live);
      // Resize immediately after EVERY attach — the tmux window may carry a prior
      // client's size (reattach.md rule).
      socket.sendResize(terminal.viewWidth, terminal.viewHeight);
      _sub = socket.output.listen(
        terminal.write,
        onDone: () => _onClosed(socket.closeCode),
        onError: (_) => _onClosed(socket.closeCode),
      );
    } catch (e) {
      // The upgrade itself failed (no open socket, so no close code). A 401 here
      // is auth; anything else is treated as transient and retried.
      if (looksLikeAuthError(e)) {
        _fail();
      } else {
        _onClosed(null);
      }
    }
  }

  void _onClosed(int? code) {
    _sub?.cancel();
    _sub = null;
    _socket = null;
    if (_disposed || _stopped) return;
    switch (actionForCloseCode(code)) {
      case CloseAction.stop:
        _stopped = true;
        _set(ConnState.ended);
      case CloseAction.reauth:
        _fail();
      case CloseAction.retry:
        final delay = backoffDelay(_attempt);
        _attempt++;
        _set(ConnState.reconnecting);
        _retry = Timer(delay, _connect);
    }
  }

  void _fail() {
    _stopped = true;
    _set(ConnState.authFailed);
    onAuthFailed?.call();
  }

  void _set(ConnState s, [String? err]) {
    if (_disposed) return;
    state = s;
    error = err;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _sub?.cancel();
    _socket?.close();
    ctrl.dispose();
    super.dispose();
  }
}
