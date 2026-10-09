import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_session_controller.dart';

/// One live [ChatSessionController] per session id, shared by every view that
/// shows it (a workspace tab, a multi-chat tile, a pushed ChatScreen). The daemon
/// keeps one client socket per session — latest attach wins — so two
/// controllers for the same session would steal the stream from each other.
/// Ref-counted: the first [acquire] creates + starts, the last [release] disposes.
class ChatControllerPool {
  final _entries = <String, _Entry>{};

  /// The shared controller for [sessionId], creating + starting it via [create]
  /// if none is live. [onAuthFailed] is this holder's re-auth handler; the most
  /// recent still-held one runs on 4401. Pair every call with [release].
  ChatSessionController acquire(
    String sessionId,
    ChatSessionController Function() create, {
    required void Function() onAuthFailed,
  }) {
    final e = _entries.putIfAbsent(sessionId, () {
      final entry = _Entry(create());
      entry.controller.onAuthFailed = () {
        if (entry.authHandlers.isNotEmpty) entry.authHandlers.last();
      };
      entry.controller.start();
      return entry;
    });
    e.authHandlers.add(onAuthFailed);
    return e.controller;
  }

  /// Drop one hold taken by [acquire] with the same [onAuthFailed]; disposes the
  /// controller (closing its socket) when nobody holds it any more.
  void release(String sessionId, void Function() onAuthFailed) {
    final e = _entries[sessionId];
    if (e == null) return;
    e.authHandlers.remove(onAuthFailed);
    if (e.authHandlers.isEmpty) {
      _entries.remove(sessionId);
      e.controller.dispose();
    }
  }
}

class _Entry {
  _Entry(this.controller);
  final ChatSessionController controller;
  final authHandlers = <void Function()>[];
}

final chatControllerPoolProvider = Provider<ChatControllerPool>((ref) => ChatControllerPool());
