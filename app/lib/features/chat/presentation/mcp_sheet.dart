import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../domain/mcp_server.dart';
import 'chat_session_controller.dart';

/// "Tools & integrations" (proposal 43): the session's MCP servers — state, tools, and a
/// reconnect / turn-off switch. Read-mostly: it never shows how a server is launched.
Future<void> showMcpSheet(BuildContext context, ChatSessionController controller) {
  controller.requestMcp();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: McpSheet(controller: controller)),
  );
}

class McpSheet extends StatelessWidget {
  const McpSheet({super.key, required this.controller});
  final ChatSessionController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final servers = controller.mcpServers;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.xs),
              child: Row(children: [
                Expanded(child: Text('Tools & integrations', style: theme.textTheme.titleMedium)),
                IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: controller.requestMcp),
              ]),
            ),
            if (servers == null)
              const Padding(padding: EdgeInsets.all(Spacing.xl), child: Center(child: CircularProgressIndicator()))
            else if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Text('No MCP servers are configured for this session.', style: theme.textTheme.bodyMedium),
              )
            else
              Expanded(
                child: ListView(children: [
                  for (final s in servers) McpServerTile(server: s, onAction: (a) => controller.mcpAction(s.name, a)),
                  if (controller.mcpTruncated)
                    Padding(
                      padding: const EdgeInsets.all(Spacing.lg),
                      child: Text('Some servers or tools are not listed — the list is capped.', style: theme.textTheme.bodySmall),
                    ),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}

class McpServerTile extends StatelessWidget {
  const McpServerTile({super.key, required this.server, required this.onAction});
  final McpServerInfo server;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (IconData icon, Color color) = switch (server.status) {
      'connected' => (Icons.check_circle_outline, scheme.primary),
      'failed' => (Icons.error_outline, scheme.error),
      'needs-auth' => (Icons.lock_outline, scheme.tertiary),
      'pending' => (Icons.hourglass_empty, scheme.onSurfaceVariant),
      'disabled' => (Icons.do_not_disturb_on_outlined, scheme.onSurfaceVariant),
      _ => (Icons.help_outline, scheme.onSurfaceVariant),
    };
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(server.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(server.summary, style: theme.textTheme.bodySmall),
        trailing: PopupMenuButton<String>(
          tooltip: 'Actions',
          onSelected: onAction,
          itemBuilder: (_) => [
            if (server.canReconnect) const PopupMenuItem(value: 'reconnect', child: Text('Reconnect')),
            if (server.disabled)
              const PopupMenuItem(value: 'enable', child: Text('Turn on'))
            else
              const PopupMenuItem(value: 'disable', child: Text('Turn off for this chat')),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.lg, Spacing.sm),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (server.error != null) Text(server.error!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          if (server.needsAuth)
            Text(
              'This connector needs to be authorized. That can\'t be done from here — sign in from the Claude app or run `claude mcp` on the server.',
              style: theme.textTheme.bodySmall,
            ),
          if (server.scope != null) Text('Source: ${server.scope}', style: theme.textTheme.bodySmall),
          if (server.tools.isEmpty && server.connected) Text('No tools.', style: theme.textTheme.bodySmall),
          for (final t in server.tools)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(t.destructive ? Icons.warning_amber_outlined : Icons.build_outlined, size: 14, color: t.destructive ? scheme.error : null),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (t.readOnly) const TextSpan(text: '  read-only'),
                    if (t.destructive) TextSpan(text: '  can change things', style: TextStyle(color: scheme.error)),
                    if (t.description.isNotEmpty) TextSpan(text: '\n${t.description}', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]), style: theme.textTheme.bodySmall),
                ),
              ]),
            ),
          if (server.toolCount > server.tools.length)
            Text('+ ${server.toolCount - server.tools.length} more tools not listed', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
