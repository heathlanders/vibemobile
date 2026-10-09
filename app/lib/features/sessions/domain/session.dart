/// A project discovered by the daemon scanner (GET /projects).
class Project {
  const Project({
    required this.id,
    required this.path,
    this.name,
    this.type,
    this.gitBranch,
    this.lastActive,
  });

  final String id;
  final String path;
  final String? name;
  final String? type;
  final String? gitBranch;

  /// Scanner's latest-activity timestamp (ISO). Null when unknown.
  final DateTime? lastActive;

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        path: j['path'] as String,
        name: j['name'] as String?,
        type: j['type'] as String?,
        gitBranch: j['git_branch'] as String?,
        lastActive: DateTime.tryParse(j['last_active'] as String? ?? ''),
      );

  String get label => name ?? path;
}

/// Compact "3d" / "4h" / "12m" / "now" for a past timestamp; '' when unknown.
String relativeAge(DateTime? at) {
  if (at == null) return '';
  final d = DateTime.now().difference(at);
  if (d.isNegative || d.inMinutes < 1) return 'now';
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  return '${d.inMinutes}m';
}

/// A selectable model for the picker (GET /models, ADR 0007). Operator-defined,
/// non-secret. `id` is passed on session create; the gateway routes it upstream.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.label,
    this.provider,
    this.priceIn,
    this.priceOut,
    this.context,
    this.tags = const [],
  });

  final String id;
  final String label;
  final String? provider;

  /// USD per 1M tokens, when the registry knows it (ADR 0016).
  final double? priceIn;
  final double? priceOut;

  /// Context window in tokens, when known.
  final int? context;

  /// Strength hints ("coding", "fast", "cheap", …) from the operator's models file.
  final List<String> tags;

  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    final price = j['price'] as Map<String, dynamic>?;
    return ModelInfo(
      id: j['id'] as String,
      label: (j['label'] as String?) ?? (j['id'] as String),
      provider: j['provider'] as String?,
      priceIn: (price?['in'] as num?)?.toDouble(),
      priceOut: (price?['out'] as num?)?.toDouble(),
      context: (j['context'] as num?)?.toInt(),
      tags: (j['tags'] as List<dynamic>?)?.whereType<String>().toList() ?? const [],
    );
  }

  /// "openai · $1.25/$10 per M · 400k ctx · coding, fast" — the picker subtitle.
  String get detail {
    String usd(double v) => '\$${v < 1 ? v.toStringAsFixed(2) : v.toStringAsFixed(v % 1 == 0 ? 0 : 2)}';
    String ctx(int t) => t >= 1000000 ? '${(t / 1000000).toStringAsFixed(t % 1000000 == 0 ? 0 : 1)}M' : '${t ~/ 1000}k';
    return [
      ?provider,
      if (priceIn != null && priceOut != null) '${usd(priceIn!)}/${usd(priceOut!)} per M',
      if (context != null) '${ctx(context!)} ctx',
      if (tags.isNotEmpty) tags.join(', '),
    ].join(' · ');
  }
}

/// A terminal/claude session (GET/POST /sessions). `status` ∈ live|dead|stale.
class Session {
  const Session({
    required this.id,
    required this.projectId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.title,
    this.tags = const [],
    this.model,
    this.totalCostUsd = 0,
    this.claudeSessionId,
    this.externalStatus,
    this.worktreeBranch,
  });

  final String id;
  final String projectId;
  final String kind;
  final String status;
  final String createdAt;
  final String? title;

  /// Grouping labels (proposal 12), stored server-side as a CSV string.
  final List<String> tags;

  /// Chosen upstream model id (ADR 0007), claude sessions only. null = default.
  final String? model;

  /// Accumulated spend (native/pay-per-token sessions; 0 on a Max subscription,
  /// where the token→dollar figure would be fiction).
  final double totalCostUsd;

  /// Agent SDK / CLI transcript id. Set on claude rows that have run at least
  /// once, including ones discovered from a `claude` CLI started outside the
  /// daemon (session-rest.md "External sessions").
  final String? claudeSessionId;

  /// `busy`/`idle` while a `claude` CLI on the server is running this session
  /// right now (ADR 0012) — opening it mirrors that CLI. Null otherwise.
  final String? externalStatus;

  /// `vibe/<id>` when this session runs in its own git worktree (ADR 0022).
  final String? worktreeBranch;

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        id: j['id'] as String,
        projectId: j['project_id'] as String,
        kind: j['kind'] as String,
        status: j['status'] as String,
        createdAt: j['created_at'] as String,
        title: j['title'] as String?,
        tags: (j['tags'] as String?)?.split(',').where((t) => t.isNotEmpty).toList() ?? const [],
        model: j['model'] as String?,
        totalCostUsd: (j['total_cost_usd'] as num?)?.toDouble() ?? 0,
        claudeSessionId: j['claude_session_id'] as String?,
        externalStatus: (j['external'] as Map<String, dynamic>?)?['status'] as String?,
        worktreeBranch: j['worktree_branch'] as String?,
      );

  bool get isLive => status == 'live';

  /// Tappable: live, or a non-live claude row with a transcript to resume —
  /// attaching resumes it and the daemon flips it back to live (claude-ws.md).
  bool get canOpen => isLive || (kind == 'claude' && claudeSessionId != null);
  String get label => title ?? id;

  /// "$0.042" / "$1.20", or '' when nothing has been spent (Max sessions).
  String get costLabel =>
      totalCostUsd <= 0 ? '' : '\$${totalCostUsd < 1 ? totalCostUsd.toStringAsFixed(3) : totalCostUsd.toStringAsFixed(2)}';
}

/// Case-insensitive match of [session] (within [projectName]) against a free-text
/// [query] over project name / title / kind / status / id. Empty query matches.
/// Pure → unit-tested.
bool sessionMatches(Session session, String projectName, String query) {
  if (query.trim().isEmpty) return true;
  final q = query.toLowerCase();
  bool has(String? s) => (s ?? '').toLowerCase().contains(q);
  return has(projectName) || has(session.title) || has(session.kind) || has(session.status) || has(session.id);
}
