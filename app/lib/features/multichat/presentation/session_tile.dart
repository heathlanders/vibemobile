import 'package:flutter/material.dart';

import '../../../core/reconnect.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/presentation/chat_session_controller.dart';
import '../../sessions/domain/session.dart';

/// One cell of the multi-chat grid (proposal 19): a live, read-only tail of a
/// session's transcript with status/busy/approval indicators. Tap expands to the
/// full ChatScreen on the SAME controller (the daemon keeps one socket per
/// session, so the tile must never open its own).
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.session,
    required this.controller,
    required this.onTap,
    required this.onRemove,
  });

  final Session session;
  final ChatSessionController controller;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  /// How many transcript rows a tile renders at most — enough to fill a cell,
  /// cheap enough for six tiles streaming at once.
  static const tailLength = 8;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              Expanded(child: _tail(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = Theme.of(context).extension<AppColors>()!;
    // Same state→token mapping as the chat _Banner (DESIGN.md §2): live = no
    // indicator at all; anything else gets its named connection color.
    final dot = switch (controller.state) {
      ConnState.live => null,
      ConnState.connecting => colors.connConnecting,
      ConnState.reconnecting => colors.connReconnecting,
      ConnState.ended => colors.connEnded,
      ConnState.authFailed => colors.connAuthFailed,
    };
    final approval = controller.pendingPermission != null || controller.pendingDialog != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.xs, 0),
      child: Row(
        children: [
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: Spacing.sm),
          ],
          Expanded(
            child: Text(
              controller.title ?? session.label,
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (controller.busy)
            const Padding(
              padding: EdgeInsets.only(left: Spacing.xs),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (approval)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.xs),
              child: Icon(Icons.lock_outline, size: 16, color: scheme.tertiary),
            ),
          IconButton(
            tooltip: 'Remove from grid',
            icon: const Icon(Icons.close, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }

  /// Keep the END of a long assistant turn visible — while streaming, the newest
  /// tokens are what the user is monitoring; maxLines would clip them off.
  static String _tailText(String text) =>
      text.length > 300 ? '…${text.substring(text.length - 300)}' : text;

  /// Compact transcript tail: newest at the bottom via `reverse: true` (free
  /// tail-follow, no scroll bookkeeping), plain Text rows — no bubbles, images,
  /// or expansion tiles at this size.
  Widget _tail(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    final rows = [
      for (final m in controller.messages)
        if (m.role != ChatRole.result && m.role != ChatRole.thinking && m.role != ChatRole.notice && (m.text.isNotEmpty || m.role == ChatRole.tool || m.images.isNotEmpty)) m,
    ];
    final tail = rows.length > tailLength ? rows.sublist(rows.length - tailLength) : rows;
    if (controller.state == ConnState.ended && tail.isEmpty) {
      return Center(child: Text('Session ended', style: style));
    }
    return ListView.builder(
      reverse: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.xs),
      itemCount: tail.length,
      itemBuilder: (context, i) {
        final m = tail[tail.length - 1 - i]; // reversed list: index 0 = newest
        final (String text, Color? color) = switch (m.role) {
          ChatRole.user => ('You: ${m.images.isNotEmpty ? '[image] ' : ''}${m.text}', scheme.primary),
          ChatRole.assistant => (_tailText(m.text) + (m.streaming ? ' ▍' : ''), null),
          ChatRole.tool => ('⚙ ${m.toolName ?? 'tool'}', scheme.outline),
          ChatRole.error => (m.text, scheme.error),
          ChatRole.result || ChatRole.thinking || ChatRole.notice => ('', null),
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: Spacing.xs),
          child: Text(
            text,
            style: color == null ? style : style?.copyWith(color: color),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}
