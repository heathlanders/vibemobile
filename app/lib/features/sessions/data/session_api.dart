import 'package:dio/dio.dart';

import '../../../core/chat_settings.dart';
import '../../chat/domain/session_mode.dart';
import '../domain/session.dart';

/// REST client for the daemon's project/session endpoints. All routes are
/// bearer-gated; the [Dio] passed in is pre-configured with the token
/// (see `dioFor` in core/providers.dart).
class SessionApi {
  SessionApi(this._dio);
  final Dio _dio;

  Future<List<Project>> projects() async {
    final res = await _dio.get<List<dynamic>>('/projects');
    return (res.data ?? []).map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Session>> sessions(String projectId) async {
    final res = await _dio.get<List<dynamic>>('/sessions', queryParameters: {'project_id': projectId});
    return (res.data ?? []).map((e) => Session.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Every session across all projects (dashboard counts + session switcher).
  Future<List<Session>> allSessions() async {
    final res = await _dio.get<List<dynamic>>('/sessions');
    return (res.data ?? []).map((e) => Session.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Models available through the daemon's gateway (ADR 0007). Operator-defined,
  /// non-secret; the phone renders these in the picker and passes the chosen
  /// [ModelInfo.id] to [create].
  Future<List<ModelInfo>> models() async {
    final res = await _dio.get<Map<String, dynamic>>('/models');
    final list = (res.data?['models'] as List<dynamic>?) ?? const [];
    // Drop malformed entries (missing/empty id) so one bad model can't crash the
    // picker — a stale gateway may emit id-less rows the daemon now filters.
    return list
        .whereType<Map<String, dynamic>>()
        .where((e) => e['id'] is String && (e['id'] as String).isNotEmpty)
        .map(ModelInfo.fromJson)
        .toList();
  }

  /// Agent CLI presets installed on the server (ADR 0016) — ids + labels.
  Future<List<AgentPreset>> presets() async {
    final res = await _dio.get<Map<String, dynamic>>('/presets');
    final list = (res.data?['presets'] as List<dynamic>?) ?? const [];
    return list.whereType<Map<String, dynamic>>().map(AgentPreset.fromJson).toList();
  }

  /// [initialPrompt] (claude only, proposal 15) primes the first turn atomically:
  /// the daemon queues it when the SDK starts on attach, so there's no
  /// create-then-send race on a flaky first connect. [model] (claude only,
  /// ADR 0007) selects the upstream model; null = the gateway/CLI default.
  /// [preset] (terminal only, ADR 0016) starts an agent CLI by server-side id.
  /// [mode] (claude only, proposal 25) is the session's starting mode; null =
  /// the user's "default mode for new sessions" setting.
  /// [worktree] (claude only, ADR 0022) runs it in its own git worktree.
  Future<Session> create(
    String projectId, {
    String kind = 'terminal',
    String? title,
    String? initialPrompt,
    String? model,
    String? preset,
    SessionMode? mode,
    bool worktree = false,
  }) async {
    final startMode = kind == 'claude' ? (mode ?? await loadDefaultMode()) : null;
    final res = await _dio.post<Map<String, dynamic>>(
      '/sessions',
      data: {
        'project_id': projectId,
        'kind': kind,
        'title': ?title,
        'initialPrompt': ?initialPrompt,
        'model': ?model,
        'preset': ?preset,
        'mode': ?startMode?.wire,
        if (worktree) 'worktree': true,
      },
    );
    // dio's validateStatus lets 4xx through (see dioFor), so a cap/validation
    // error arrives as a body without `id` — surface it instead of cast-crashing.
    final data = res.data;
    if (data == null || data['id'] == null) {
      throw Exception((data?['error'] as String?) ?? 'could not create session (${res.statusCode})');
    }
    return Session.fromJson(data);
  }

  /// One session by id (notification tap → open it). Null when it's gone.
  Future<Session?> get(String sessionId) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId');
    return res.statusCode == 200 && res.data != null ? Session.fromJson(res.data!) : null;
  }

  Future<Session> rename(String sessionId, String title) async {
    final res = await _dio.patch<Map<String, dynamic>>('/sessions/$sessionId', data: {'title': title});
    return Session.fromJson(res.data!);
  }

  /// Set a session's grouping tags (proposal 12). Sent as CSV; the daemon
  /// normalizes (trim/dedupe) and stores null when empty.
  Future<Session> setTags(String sessionId, List<String> tags) async {
    final res = await _dio.patch<Map<String, dynamic>>('/sessions/$sessionId', data: {'tags': tags.join(',')});
    return Session.fromJson(res.data!);
  }

  /// Search a session's transcript (proposal 10). Empty [q] returns the latest
  /// messages. Results are newest-first.
  Future<List<MessageHit>> searchMessages(String sessionId, String q) async {
    final res = await _dio.get<List<dynamic>>(
      '/sessions/$sessionId/messages',
      queryParameters: q.isEmpty ? null : {'q': q},
    );
    return (res.data ?? []).map((e) => MessageHit.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Ends + removes the session. Returns where its worktree was left on the server
  /// when it held work that was worth keeping (ADR 0022), else null.
  Future<WorktreeKept?> delete(String sessionId) async {
    final res = await _dio.delete<Map<String, dynamic>>('/sessions/$sessionId');
    final d = res.data;
    return res.statusCode == 200 && d != null && d['kept'] == true ? WorktreeKept.fromJson(d) : null;
  }

  /// Bulk-delete a project's stale sessions (optionally only those older than
  /// [olderThanDays]). Returns how many were removed; transcripts stay on disk.
  Future<int> pruneStale(String projectId, {int? olderThanDays}) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/sessions/prune',
      data: {'project_id': projectId, 'older_than_days': ?olderThanDays},
    );
    final data = res.data;
    if (data == null || data['deleted'] == null) {
      throw Exception((data?['error'] as String?) ?? 'could not clear sessions (${res.statusCode})');
    }
    return data['deleted'] as int;
  }
}

/// A worktree the daemon kept on delete because it held work (ADR 0022).
class WorktreeKept {
  const WorktreeKept({required this.path, this.branch, this.reason});
  final String path;
  final String? branch;

  /// `dirty` (uncommitted changes) | `commits` (unmerged commits) | `error`.
  final String? reason;

  factory WorktreeKept.fromJson(Map<String, dynamic> j) =>
      WorktreeKept(path: j['path'] as String? ?? '', branch: j['branch'] as String?, reason: j['reason'] as String?);

  String get message {
    final why = switch (reason) {
      'dirty' => 'uncommitted changes',
      'commits' => 'unmerged commits',
      _ => 'work that could not be checked',
    };
    return 'Kept the isolated copy on the server ($why): $path${branch == null ? '' : ' · $branch'}';
  }
}

/// A transcript search hit (proposal 10): one matching `messages` row.
class MessageHit {
  const MessageHit({required this.id, required this.role, required this.content, required this.ts});
  final String id;
  final String role;
  final String content;
  final String ts;

  factory MessageHit.fromJson(Map<String, dynamic> j) => MessageHit(
        id: j['id'] as String,
        role: j['role'] as String,
        content: (j['content'] as String?) ?? '',
        ts: j['ts'] as String,
      );
}

/// An agent CLI the server can start in a terminal session (ADR 0016).
class AgentPreset {
  const AgentPreset({required this.id, required this.label});
  final String id;
  final String label;

  factory AgentPreset.fromJson(Map<String, dynamic> j) =>
      AgentPreset(id: j['id'] as String, label: (j['label'] as String?) ?? (j['id'] as String));
}
