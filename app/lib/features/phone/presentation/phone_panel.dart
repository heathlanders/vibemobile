import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/session_attention.dart';
import '../../../core/spacing.dart';
import '../../../core/widgets.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';

/// Rail selection meaning "running or needs-you sessions across all projects".
const phoneLiveId = '__live';

/// Width of the project rail (Discord's server list).
const phoneRailWidth = 72.0;

typedef PhoneCreate = void Function(String kind, {String? preset, bool worktree});

/// The navigation panel behind the content: project rail on the left, the
/// selected project's sessions (or the Live list) beside it.
class PhonePanel extends ConsumerWidget {
  const PhonePanel({
    super.key,
    required this.projects,
    required this.sessions,
    required this.error,
    required this.selected,
    required this.titles,
    required this.presets,
    required this.activeSessionId,
    required this.onSelect,
    required this.onOpen,
    required this.onCreate,
    required this.onNewProject,
    required this.onRefresh,
  });

  /// Null while the first load is in flight.
  final List<Project>? projects;
  final List<Session> sessions;
  final String? error;
  final String selected; // a project id or [phoneLiveId]
  final Map<String, String> titles; // live chat titles by session id
  final List<AgentPreset> presets;
  final String? activeSessionId;
  final void Function(String) onSelect;
  final void Function(Session) onOpen;
  final PhoneCreate onCreate;
  final VoidCallback onNewProject;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attention = ref.watch(sessionAttentionProvider);
    final scheme = Theme.of(context).colorScheme;
    final all = projects ?? const <Project>[];
    final project = all.where((p) => p.id == selected).firstOrNull;
    final liveCounts = <String, int>{};
    for (final s in sessions.where((s) => s.isLive)) {
      liveCounts[s.projectId] = (liveCounts[s.projectId] ?? 0) + 1;
    }
    return SafeArea(
      bottom: false,
      child: Row(
        children: [
          SizedBox(
            width: phoneRailWidth,
            child: Material(
              color: scheme.surfaceContainerLow,
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                      children: [
                        _RailItem(
                          tooltip: 'Live',
                          selected: selected == phoneLiveId,
                          badge: attention.length,
                          onTap: () => onSelect(phoneLiveId),
                          icon: Icons.bolt_outlined,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.xs),
                          child: Divider(height: 1),
                        ),
                        for (final p in all)
                          _RailItem(
                            tooltip: p.label,
                            selected: p.id == selected,
                            badge: liveCounts[p.id] ?? 0,
                            badgeColor: scheme.primary,
                            onTap: () => onSelect(p.id),
                            initials: _initials(p.label),
                          ),
                      ],
                    ),
                  ),
                  _RailItem(tooltip: 'New project', selected: false, onTap: onNewProject, icon: Icons.add),
                  const SizedBox(height: Spacing.sm),
                ],
              ),
            ),
          ),
          Expanded(
            child: Material(
              color: scheme.surfaceContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    title: selected == phoneLiveId ? 'Live' : (project?.label ?? ''),
                    subtitle: selected == phoneLiveId ? 'Running or waiting for you' : project?.gitBranch,
                  ),
                  if (project != null) _Actions(presets: presets, onCreate: onCreate),
                  const Divider(height: 1),
                  Expanded(child: _list(context, attention, project)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, Map<String, Attention> attention, Project? project) {
    if (error != null && projects == null) return ErrorBody(message: error!);
    if (projects == null) return const SkeletonList(rows: 5);
    final live = selected == phoneLiveId;
    final rows =
        sessions
            .where(
              (s) =>
                  live ? (s.isLive && s.canOpen) || attention.containsKey(s.id) : s.projectId == selected && s.canOpen,
            )
            .toList()
          ..sort((a, b) {
            final byLive = (b.isLive ? 1 : 0) - (a.isLive ? 1 : 0);
            return byLive != 0 ? byLive : b.createdAt.compareTo(a.createdAt);
          });
    final names = {for (final p in projects!) p.id: p.label};
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: rows.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 280,
                  child: EmptyState(
                    icon: live ? Icons.bolt_outlined : Icons.chat_bubble_outline,
                    title: live ? 'Nothing running' : 'No sessions yet',
                    hint: live
                        ? 'Sessions that are live or need you show up here.'
                        : 'Start a chat or a terminal above.',
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final s = rows[i];
                return _SessionTile(
                  session: s,
                  title: titles[s.id] ?? s.label,
                  subtitle: live ? names[s.projectId] : (s.externalStatus != null ? 'on PC' : s.worktreeBranch),
                  attention: attention[s.id],
                  selected: s.id == activeSessionId,
                  onTap: () => onOpen(s),
                );
              },
            ),
    );
  }
}

/// "demo-app" -> "DA", "docs" -> "D".
String _initials(String name) {
  final words = name.split(RegExp(r'[\s\-_./]+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final letters = words.length == 1 ? words.first.substring(0, 1) : words[0].substring(0, 1) + words[1].substring(0, 1);
  return letters.toUpperCase();
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.tooltip,
    required this.selected,
    required this.onTap,
    this.icon,
    this.initials,
    this.badge = 0,
    this.badgeColor,
  });
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? initials;
  final int badge;
  final Color? badgeColor;

  static const size = 48.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    // Rounded square at rest, a circle with the primary fill when selected.
    final avatar = AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.enter,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(selected ? size / 2 : Radii.md),
      ),
      child: icon != null
          ? Icon(icon, color: fg)
          : Text(initials ?? '', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: fg)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Center(
        child: Tooltip(
          message: tooltip,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: badgeColor == null
                // Live: the red pulsing attention badge.
                ? FlashingBadge(count: badge, child: avatar)
                : Badge(label: Text('$badge'), isLabelVisible: badge > 0, backgroundColor: badgeColor, child: avatar),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (subtitle != null)
            Text(subtitle!, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.presets, required this.onCreate});
  final List<AgentPreset> presets;
  final PhoneCreate onCreate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, 0, Spacing.md, Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.smart_toy_outlined, size: 18),
              label: const Text('New chat'),
              onPressed: () => onCreate('claude'),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.terminal, size: 18),
              label: const Text('Terminal'),
              onPressed: () => onCreate('terminal'),
            ),
          ),
          if (presets.isNotEmpty)
            PopupMenuButton<AgentPreset>(
              tooltip: 'Start an agent CLI',
              icon: const Icon(Icons.rocket_launch_outlined),
              onSelected: (p) => onCreate('terminal', preset: p.id),
              itemBuilder: (_) => [for (final p in presets) PopupMenuItem(value: p, child: Text(p.label))],
            ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.title,
    required this.subtitle,
    required this.attention,
    required this.selected,
    required this.onTap,
  });
  final Session session;
  final String title;
  final String? subtitle;
  final Attention? attention;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      leading: Icon(
        session.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal,
        color: session.isLive ? scheme.primary : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: attention != null
          ? Icon(Icons.circle, size: 10, color: scheme.error, semanticLabel: 'Needs you')
          : (session.isLive ? Icon(Icons.circle, size: 10, color: scheme.primary, semanticLabel: 'Live') : null),
      onTap: onTap,
    );
  }
}
