import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/chat/domain/session_mode.dart';

const _kDefaultMode = 'default_session_mode';
// Pre-proposal-25 boolean ("Auto-allow tool permissions"); read once as a fallback.
const _kLegacyAutoAllow = 'auto_allow_permissions';

Future<SessionMode> _readDefaultMode() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = SessionMode.fromWire(prefs.getString(_kDefaultMode));
  if (stored != null) return stored;
  return (prefs.getBool(_kLegacyAutoAllow) ?? true) ? SessionMode.auto : SessionMode.ask;
}

/// The mode new Claude sessions start in (proposal 25). Sent as `mode` on
/// `POST /sessions`; after that the session's own chip owns its mode — the
/// daemon is the source of truth and a reconnect never re-sends this. Fails soft
/// to null (daemon default) so session creation never depends on local storage.
Future<SessionMode?> loadDefaultMode() async {
  try {
    return await _readDefaultMode();
  } catch (_) {
    return null;
  }
}

/// Persisted "default mode for new sessions" setting. Defaults to Auto-allow
/// (matches the daemon default, claude-ws.md).
class DefaultSessionModeNotifier extends Notifier<SessionMode> {
  @override
  SessionMode build() {
    _load();
    return SessionMode.auto;
  }

  Future<void> _load() async {
    state = await _readDefaultMode();
  }

  Future<void> set(SessionMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDefaultMode, mode.wire);
  }
}

final defaultSessionModeProvider =
    NotifierProvider<DefaultSessionModeNotifier, SessionMode>(DefaultSessionModeNotifier.new);
