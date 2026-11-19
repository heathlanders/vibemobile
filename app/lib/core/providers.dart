import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'token_store.dart';

/// Secure-storage wrapper (single instance).
final tokenStoreProvider = Provider<TokenStore>((ref) => const TokenStore());

/// Current credentials, or null when unpaired. The app root watches this to
/// route between pairing and the session list; call `ref.invalidate` after
/// pairing or sign-out to re-route.
final credsProvider = FutureProvider<Creds?>((ref) {
  return ref.read(tokenStoreProvider).read();
});

/// The Dio for these creds: base URL + bearer header. `validateStatus`
/// accepts 4xx so callers can branch on `statusCode` without try/catch noise;
/// 5xx still throws. One shared instance per creds, with timeouts so a dead
/// tailnet ends in an error instead of an endless skeleton (proposal 70 C3).
/// Slow calls (uploads, downloads, git/LLM work) pass a longer per-request timeout.
Dio dioFor(Creds creds) => _dios.putIfAbsent(
      '${creds.baseUrl}\n${creds.token}',
      () => Dio(
        BaseOptions(
          baseUrl: creds.baseUrl,
          headers: {'authorization': 'Bearer ${creds.token}'},
          validateStatus: (s) => s != null && s < 500,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        ),
      ),
    );
final _dios = <String, Dio>{};

/// Per-request options for calls that legitimately outlast the 30 s default: git,
/// worktrees, `gh`, SDK transcript work, project creation (proposal 70 C3).
Options slowCall() => Options(receiveTimeout: const Duration(minutes: 5));

/// Build a `wss://…/<channel>/<id>` URL from the REST base URL (https→wss, http→ws).
Uri _wsUrl(String baseUrl, String channel, String sessionId) {
  final base = Uri.parse(baseUrl);
  final scheme = base.scheme == 'https' ? 'wss' : 'ws';
  return base.replace(scheme: scheme, pathSegments: [channel, sessionId]);
}

/// Terminal byte channel — `wss://…/pty/<id>`.
Uri ptyUrl(String baseUrl, String sessionId) => _wsUrl(baseUrl, 'pty', sessionId);

/// Claude event channel — `wss://…/session/<id>`.
Uri claudeUrl(String baseUrl, String sessionId) => _wsUrl(baseUrl, 'session', sessionId);

/// A running `vc` CLI session's own TUI (ADR 0012) — `wss://…/session/<id>/tty`.
Uri ttyUrl(String baseUrl, String sessionId) {
  final base = Uri.parse(baseUrl);
  return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', pathSegments: ['session', sessionId, 'tty']);
}
