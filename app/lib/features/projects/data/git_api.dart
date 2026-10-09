import 'package:dio/dio.dart';

/// One entry from `git status --porcelain` — [index]/[worktree] are the two
/// status characters (' ', 'M', 'A', 'D', '?', …).
class GitFile {
  const GitFile({required this.path, required this.index, required this.worktree});

  final String path;
  final String index;
  final String worktree;

  bool get untracked => index == '?' && worktree == '?';

  /// Already in the index (will be part of the next commit whether or not the user
  /// ticks it) — `?` is untracked, ' ' is nothing staged.
  bool get staged => index != ' ' && index != '?';

  /// Mirrors the daemon's secret deny-list (git-write.ts): such files can't be
  /// staged from the app — use a terminal if you really mean to.
  bool get looksSecret {
    final name = path.split('/').last;
    return RegExp(r'^\.env(\..*)?$', caseSensitive: false).hasMatch(name) ||
        RegExp(r'\.(pem|key|p12|pfx)$', caseSensitive: false).hasMatch(name) ||
        RegExp(r'^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$', caseSensitive: false).hasMatch(name) ||
        name.toLowerCase() == '.netrc';
  }

  factory GitFile.fromJson(Map<String, dynamic> j) => GitFile(
        path: j['path'] as String? ?? '',
        index: j['index'] as String? ?? ' ',
        worktree: j['worktree'] as String? ?? ' ',
      );
}

/// Read-only working-tree status (`GET /projects/:id/git-status`, ADR 0011).
/// [repo] is false when the project isn't a git repo at all.
class GitStatus {
  const GitStatus({
    required this.repo,
    required this.clean,
    required this.files,
    required this.truncated,
    this.branch,
    this.ahead = 0,
    this.behind = 0,
  });

  final bool repo;
  final bool clean;
  final List<GitFile> files;
  final bool truncated;
  final String? branch;
  final int ahead;
  final int behind;

  factory GitStatus.fromJson(Map<String, dynamic> j) => GitStatus(
        repo: j['repo'] == true,
        clean: j['clean'] == true,
        branch: j['branch'] as String?,
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
        truncated: j['truncated'] == true,
        files: ((j['files'] as List?) ?? const [])
            .map((e) => GitFile.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  /// "main · 3 changed · ahead 1" — the one-line summary for the status strip.
  String get summary {
    if (!repo) return 'Not a git repo';
    final parts = <String>[
      branch ?? 'detached',
      if (clean) 'clean' else '${files.length}${truncated ? '+' : ''} changed',
      if (ahead > 0) 'ahead $ahead',
      if (behind > 0) 'behind $behind',
    ];
    return parts.join(' · ');
  }
}

/// Outcome of a git write (`/sessions/:id/git/...`, ADR 0024). The daemon's error
/// text is short and generic, so it is safe to show as-is.
class GitWriteResult {
  const GitWriteResult({required this.ok, this.error, this.sha, this.subject, this.staged = const []});
  final bool ok;
  final String? error;
  final String? sha;
  final String? subject;
  final List<String> staged;

  factory GitWriteResult.fromResponse(int? status, Map<String, dynamic>? j) => GitWriteResult(
        ok: status == 200,
        error: status == 200 ? null : (j?['error'] as String? ?? 'request failed ($status)'),
        sha: j?['sha'] as String?,
        subject: j?['subject'] as String?,
        staged: ((j?['staged'] as List?) ?? const []).cast<String>(),
      );

  String get shortSha => sha == null ? '' : sha!.substring(0, sha!.length < 7 ? sha!.length : 7);
}

class GitApi {
  GitApi(this._dio);
  final Dio _dio;

  Future<GitStatus> status(String projectId) async {
    final res = await _dio.get<Map<String, dynamic>>('/projects/$projectId/git-status');
    return GitStatus.fromJson(res.data ?? const {});
  }

  /// Status of the session's own checkout (its worktree if it has one, ADR 0022).
  Future<GitStatus> sessionStatus(String sessionId) async {
    final res = await _dio.get<Map<String, dynamic>>('/sessions/$sessionId/git-status');
    return GitStatus.fromJson(res.data ?? const {});
  }

  /// Stage exactly [paths] (literal, repo-relative). Never sends `allowSensitive`.
  Future<GitWriteResult> stage(String sessionId, List<String> paths) async {
    final res = await _dio.post<Map<String, dynamic>>('/sessions/$sessionId/git/stage', data: {'paths': paths});
    return GitWriteResult.fromResponse(res.statusCode, res.data);
  }

  Future<GitWriteResult> commit(String sessionId, String message) async {
    final res = await _dio.post<Map<String, dynamic>>('/sessions/$sessionId/git/commit', data: {'message': message});
    return GitWriteResult.fromResponse(res.statusCode, res.data);
  }

  Future<GitWriteResult> branch(String sessionId, String name) async {
    final res = await _dio.post<Map<String, dynamic>>('/sessions/$sessionId/git/branch', data: {'name': name});
    return GitWriteResult.fromResponse(res.statusCode, res.data);
  }
}
