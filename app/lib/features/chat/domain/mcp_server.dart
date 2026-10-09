/// An MCP server of the current session as the daemon reports it (`mcp` frame, proposal 43).
/// The daemon never sends launch commands, env vars or URLs — only what is shown here.
class McpTool {
  const McpTool({required this.name, this.description = '', this.readOnly = false, this.destructive = false});
  final String name;
  final String description;
  final bool readOnly;
  final bool destructive;
}

class McpServerInfo {
  const McpServerInfo({
    required this.name,
    required this.status,
    this.version,
    this.scope,
    this.error,
    this.toolCount = 0,
    this.tools = const [],
  });

  final String name;

  /// `connected` | `failed` | `needs-auth` | `pending` | `disabled` | `unknown`.
  final String status;
  final String? version;
  final String? scope;
  final String? error;

  /// The server's real tool count; [tools] may be shorter when the daemon capped the list.
  final int toolCount;
  final List<McpTool> tools;

  bool get connected => status == 'connected';
  bool get needsAuth => status == 'needs-auth';
  bool get disabled => status == 'disabled';

  /// Reconnect only makes sense for a server that isn't up and isn't switched off.
  bool get canReconnect => status == 'failed' || status == 'pending' || status == 'unknown';

  String get statusLabel => switch (status) {
        'connected' => 'Connected',
        'failed' => 'Failed to start',
        'needs-auth' => 'Needs authorization',
        'pending' => 'Connecting…',
        'disabled' => 'Turned off',
        _ => 'Unknown',
      };

  /// `Connected · 12 tools · v1.4.2` — one line for the list.
  String get summary => [
        statusLabel,
        if (connected || toolCount > 0) '$toolCount tool${toolCount == 1 ? '' : 's'}',
        if (version != null) 'v$version',
      ].join(' · ');

  /// Type-safe: junk yields null instead of throwing out of the frame handler.
  static McpServerInfo? tryFromJson(Object? j) {
    if (j is! Map || j['name'] is! String || (j['name'] as String).isEmpty) return null;
    final tools = <McpTool>[
      if (j['tools'] is List)
        for (final t in j['tools'] as List)
          if (t is Map && t['name'] is String)
            McpTool(
              name: t['name'] as String,
              description: t['description'] is String ? t['description'] as String : '',
              readOnly: t['readOnly'] == true,
              destructive: t['destructive'] == true,
            ),
    ];
    return McpServerInfo(
      name: j['name'] as String,
      status: j['status'] is String ? j['status'] as String : 'unknown',
      version: j['version'] is String ? j['version'] as String : null,
      scope: j['scope'] is String ? j['scope'] as String : null,
      error: j['error'] is String && (j['error'] as String).isNotEmpty ? j['error'] as String : null,
      toolCount: j['toolCount'] is num ? (j['toolCount'] as num).toInt() : tools.length,
      tools: tools,
    );
  }
}
