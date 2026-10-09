import 'dart:math';

/// Shared reconnect primitives for the terminal and chat session controllers
/// (docs/protocols/reattach.md). Pure → unit-tested.

enum ConnState { connecting, live, reconnecting, ended, authFailed }

/// What to do when the socket closes with [code].
enum CloseAction { stop, reauth, retry }

CloseAction actionForCloseCode(int? code) {
  switch (code) {
    case 1000: // user/server closed normally
    case 4404: // session not found / ended — never silently resurrect
    case 4429: // live-session cap hit on resume — retrying can't free a slot
      return CloseAction.stop;
    case 4401: // auth failed / token expired
      return CloseAction.reauth;
    default: // 1006, 1012, null (failed connect), … — transient
      return CloseAction.retry;
  }
}

/// Backoff for attempt [attempt] (0-based): 0.5,1,2,4,8s, capped 10s, ±20% jitter.
Duration backoffDelay(int attempt, {double Function()? rng}) {
  final base = 0.5 * pow(2, attempt).toDouble();
  final capped = min(base, 10.0);
  final r = (rng ?? Random().nextDouble)();
  final jitter = 1 + (r * 0.4 - 0.2); // 0.8 … 1.2
  return Duration(milliseconds: (capped * jitter * 1000).round());
}

/// True if a connect-time exception looks like an auth failure (the upgrade was
/// refused with 401/403, so there's no close code to read).
bool looksLikeAuthError(Object e) {
  final s = e.toString();
  return s.contains('401') || s.contains('403');
}
