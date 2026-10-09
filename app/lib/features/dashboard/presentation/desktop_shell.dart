import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/session_attention.dart';
import '../../../core/token_store.dart';
import '../../multichat/presentation/multi_chat_screen.dart';
import '../../prompts/presentation/prompt_list_screen.dart';
import '../../sessions/presentation/session_search_screen.dart';
import '../../sessions/presentation/session_switcher.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../system/presentation/system_screen.dart';
import '../../usage/presentation/plan_usage_meter.dart';
import '../../usage/presentation/usage_screen.dart';
import '../../workspace/presentation/workspace_screen.dart';
import 'dashboard_screen.dart';

/// Wide-window home (ADR 0015): a NavigationRail swaps the dashboard's
/// app-bar entry points into the content area instead of pushing routes.
/// Narrow windows keep the phone layout ([DashboardScreen]). The workspace
/// stays mounted while other pages show, so its tabs keep their sockets.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.creds});
  final Creds creds;

  /// Window width at which the rail replaces the phone layout.
  static const breakpoint = 1000.0;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  int _index = 0;

  late final _workspace = WorkspaceScreen(creds: widget.creds);

  Widget _page(int i) => switch (i) {
        1 => DashboardScreen(creds: widget.creds, showNavActions: false),
        2 => SessionSwitcherScreen(creds: widget.creds),
        3 => MultiChatScreen(creds: widget.creds),
        4 => PromptListScreen(creds: widget.creds),
        5 => SessionSearchScreen(creds: widget.creds),
        6 => UsageScreen(creds: widget.creds),
        7 => SystemScreen(creds: widget.creds),
        _ => SettingsScreen(creds: widget.creds),
      };

  /// Workspace icon with a flashing red count of sessions that finished or are
  /// waiting on us and haven't been looked at yet.
  Widget _workspaceIcon(IconData icon) => Consumer(
        builder: (context, ref, _) =>
            FlashingBadge(count: ref.watch(sessionAttentionProvider).length, child: Icon(icon)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          labelType: NavigationRailLabelType.all,
          // Max-plan 5h/7d meters, always visible (ADR 0020); tap → Usage.
          trailingAtBottom: true,
          trailing: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 72,
              child: PlanUsageMeter(creds: widget.creds, onTap: () => setState(() => _index = 6)),
            ),
          ),
          destinations: [
            NavigationRailDestination(icon: _workspaceIcon(Icons.space_dashboard_outlined), label: const Text('Workspace')),
            const NavigationRailDestination(icon: Icon(Icons.folder_outlined), label: Text('Projects')),
            const NavigationRailDestination(icon: Icon(Icons.dynamic_feed_outlined), label: Text('Live')),
            const NavigationRailDestination(icon: Icon(Icons.grid_view_outlined), label: Text('Multi-chat')),
            const NavigationRailDestination(icon: Icon(Icons.bookmarks_outlined), label: Text('Prompts')),
            const NavigationRailDestination(icon: Icon(Icons.search), label: Text('Search')),
            const NavigationRailDestination(icon: Icon(Icons.insights_outlined), label: Text('Usage')),
            const NavigationRailDestination(icon: Icon(Icons.monitor_heart_outlined), label: Text('System')),
            const NavigationRailDestination(icon: Icon(Icons.settings_outlined), label: Text('Settings')),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            Visibility(visible: _index == 0, maintainState: true, child: _workspace),
            if (_index != 0) KeyedSubtree(key: ValueKey(_index), child: _page(_index)),
          ]),
        ),
      ]),
    );
  }
}
