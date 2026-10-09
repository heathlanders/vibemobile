import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../multichat/presentation/multi_chat_screen.dart';
import '../../projects/presentation/new_project_screen.dart';
import '../../prompts/presentation/prompt_list_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/presentation/project_sessions_screen.dart';
import '../../sessions/presentation/session_search_screen.dart';
import '../../sessions/presentation/session_switcher.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../usage/presentation/plan_usage_meter.dart';
import '../../usage/presentation/usage_screen.dart';

/// Post-pairing home: a grid of project cards with a live-session count, plus
/// entry points to the prompt library and the session switcher.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.creds, this.showNavActions = true});
  final Creds creds;

  /// False inside [DesktopShell], whose rail already carries these entry points.
  final bool showNavActions;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late Future<(List<Project>, Map<String, int>)> _future = _load();

  Future<(List<Project>, Map<String, int>)> _load() async {
    final projects = await _api.projects();
    final sessions = await _api.allSessions();
    final counts = <String, int>{};
    for (final s in sessions.where((s) => s.isLive)) {
      counts[s.projectId] = (counts[s.projectId] ?? 0) + 1;
    }
    // Most recently touched first; projects with no timestamp sink to the end.
    projects.sort((a, b) {
      final x = a.lastActive, y = b.lastActive;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return (projects, counts);
  }

  void _go(Widget screen) => Navigator.of(context).push(sharedAxisRoute(screen));

  // Create a new project (proposal 17). On success reload the grid and drop
  // straight into the new project's sessions.
  Future<void> _newProject() async {
    final project = await Navigator.of(context).push<Project>(
      sharedAxisRoute(NewProjectScreen(creds: widget.creds)),
    );
    if (project == null || !mounted) return;
    setState(() => _future = _load());
    _go(ProjectSessionsScreen(creds: widget.creds, project: project));
  }

  /// Under [compactWidth] dp only the first [compactVisible] icons fit beside the
  /// title; the rest move into an overflow menu.
  static const compactWidth = 360.0;
  static const compactVisible = 2;

  List<Widget> _navActions(BuildContext context) {
    final items = <(String, IconData, Widget Function())>[
      ('Search sessions', Icons.search, () => SessionSearchScreen(creds: widget.creds)),
      ('Prompt library', Icons.bookmarks_outlined, () => PromptListScreen(creds: widget.creds)),
      ('Live sessions', Icons.dynamic_feed_outlined, () => SessionSwitcherScreen(creds: widget.creds)),
      ('Multi-chat', Icons.grid_view_outlined, () => MultiChatScreen(creds: widget.creds)),
      ('Usage', Icons.insights_outlined, () => UsageScreen(creds: widget.creds)),
      ('Settings', Icons.settings_outlined, () => SettingsScreen(creds: widget.creds)),
    ];
    final compact = MediaQuery.sizeOf(context).width < compactWidth;
    final shown = compact ? items.take(compactVisible) : items;
    return [
      for (final (tip, icon, screen) in shown)
        IconButton(tooltip: tip, icon: Icon(icon), onPressed: () => _go(screen())),
      if (compact)
        PopupMenuButton<Widget Function()>(
          tooltip: 'More',
          onSelected: (screen) => _go(screen()),
          itemBuilder: (_) => [
            for (final (tip, icon, screen) in items.skip(compactVisible))
              PopupMenuItem(value: screen, child: ListTile(leading: Icon(icon), title: Text(tip))),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newProject,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('New project'),
      ),
      appBar: AppBar(
        title: const Text('VibeMobile'),
        actions: [
          if (widget.showNavActions) ..._navActions(context),
        ],
      ),
      body: Column(children: [
        // Phone has no rail: the Max-plan meters ride on top (ADR 0020).
        if (widget.showNavActions)
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, 0),
            child: PlanUsageMeter(creds: widget.creds, onTap: () => _go(UsageScreen(creds: widget.creds))),
          ),
        Expanded(
          child: RefreshIndicator(
        onRefresh: () async => setState(() => _future = _load()),
        child: FutureBuilder<(List<Project>, Map<String, int>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              // Skeleton in the real grid geometry so nothing jumps on load.
              return GridView.builder(
                padding: const EdgeInsets.all(Spacing.md),
                gridDelegate: _gridDelegate,
                itemCount: 6,
                itemBuilder: (context, _) => const SkeletonBox(height: double.infinity, radius: Radii.md),
              );
            }
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            final (projects, counts) = snap.data!;
            if (projects.isEmpty) {
              return const EmptyState(
                icon: Icons.folder_off_outlined,
                title: 'No projects found',
                hint: 'Create one with the button below, or add a project dir on the server.',
              );
            }
            return GridView.builder(
              padding: const EdgeInsets.all(Spacing.md),
              gridDelegate: _gridDelegate,
              itemCount: projects.length,
              itemBuilder: (context, i) => FadeSlideIn(
                delay: Duration(milliseconds: (40 * i).clamp(0, Motion.slow.inMilliseconds)),
                child: _ProjectCard(
                  project: projects[i],
                  liveCount: counts[projects[i].id] ?? 0,
                  onTap: () => _go(ProjectSessionsScreen(creds: widget.creds, project: projects[i])),
                ),
              ),
            );
          },
        ),
      ),
        ),
      ]),
    );
  }
}

/// Shared by the grid and its loading skeleton so the two line up exactly.
const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 260,
  childAspectRatio: 1.3,
  crossAxisSpacing: Spacing.md,
  mainAxisSpacing: Spacing.md,
);

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.liveCount, required this.onTap});
  final Project project;
  final int liveCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 20),
                  const Spacer(),
                  if (liveCount > 0)
                    Badge(
                      label: Text('$liveCount'),
                      backgroundColor: scheme.primary,
                      child: const Icon(Icons.bolt, size: 18),
                    ),
                ],
              ),
              const Spacer(),
              Text(project.label, style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Spacing.xs),
              Text(
                [project.type, project.gitBranch, relativeAge(project.lastActive)]
                    .where((s) => s != null && s.isNotEmpty)
                    .join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
