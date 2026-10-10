import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform.dart';
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
/// Desktop platforms keep the shell at every width (narrow windows get the
/// compact form, below [compactBelow]); phones always keep the phone
/// layout ([DashboardScreen]); tablets only when the screen is narrow. The workspace
/// stays mounted while other pages show, so its tabs keep their sockets.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.creds});
  final Creds creds;

  /// Window width below which desktop windows go compact (icon-only rail,
  /// sidebar behind a toggle, no split/changes pane). On phones and tablets it
  /// is the width at which the rail replaces the phone layout.
  static const compactBelow = 1000.0;

  static bool get isDesktopPlatform => switch (defaultTargetPlatform) {
        TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
        _ => false,
      };

  /// Whether the shell (rather than the phone dashboard) is shown. A phone
  /// never gets it, even in landscape (proposal 54).
  static bool shown(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return isDesktopPlatform || (!isPhone(size) && size.width >= compactBelow);
  }

  static bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactBelow;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

/// Hooks the running [DesktopShell] registers so the app-level mouse
/// back/forward handler (main.dart) can drive its rail history (proposal 55).
class DesktopNav {
  static bool Function()? back;
  static bool Function()? forward;
}

class _DesktopShellState extends State<DesktopShell> {
  int _index = 0;
  final _backStack = <int>[];
  final _forwardStack = <int>[];

  @override
  void initState() {
    super.initState();
    DesktopNav.back = _back;
    DesktopNav.forward = _forward;
  }

  @override
  void dispose() {
    DesktopNav.back = null;
    DesktopNav.forward = null;
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() {
      _backStack.add(_index);
      _forwardStack.clear();
      _index = i;
    });
  }

  bool _back() {
    if (_backStack.isEmpty) return false;
    setState(() {
      _forwardStack.add(_index);
      _index = _backStack.removeLast();
    });
    return true;
  }

  bool _forward() {
    if (_forwardStack.isEmpty) return false;
    setState(() {
      _backStack.add(_index);
      _index = _forwardStack.removeLast();
    });
    return true;
  }

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
    final compact = DesktopShell.isCompact(context);
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: _index,
          onDestinationSelected: _select,
          labelType: compact ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          // Max-plan 5h/7d meters, always visible (ADR 0020); tap → Usage.
          trailingAtBottom: true,
          trailing: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 72,
              child: PlanUsageMeter(creds: widget.creds, onTap: () => _select(6)),
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
