import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/session_attention.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/data/file_edits_api.dart';
import '../../chat/presentation/changed_files_sheet.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../dashboard/presentation/desktop_shell.dart';
import '../../notes/presentation/notes_panel.dart';
import '../../projects/data/git_api.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/presentation/model_picker.dart';
import '../../sessions/presentation/session_actions.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/workspace_prefs.dart';
import 'command_palette.dart';

/// Desktop workspace (ADR 0015, roadmap phase 1): projects + sessions on the
/// left, sessions as tabs in the middle (optionally split in two), the active
/// chat's changed files on the right.
///
/// Every open tab stays mounted so its socket, scrollback and draft survive tab
/// switches; hidden tabs sit under `Visibility(maintainState)`, which also
/// disables their tickers — ChatScreen reads that to keep notifying for prompts
/// in tabs you can't see. A GlobalKey per tab lets a session move between the
/// visible panes and the hidden stack without being rebuilt.
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.creds});
  final Creds creds;

  /// Open tabs cap — each one holds a live socket.
  static const maxTabs = 8;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late Future<List<Project>> _projects = _api.projects();
  late Future<List<AgentPreset>> _presets = _api.presets().catchError((_) => <AgentPreset>[]);

  final _tabs = <Session>[];
  final _keys = <String, GlobalKey>{};
  final _titles = <String, String>{}; // live display titles from open chats (ADR 0009)
  String? _active;
  String? _split; // second visible tab, right pane
  bool _showChanges = true;
  final _scaffoldKey = GlobalKey<ScaffoldState>(); // compact mode: sidebar drawer
  int _sidebarGen = 0; // bump → expanded project lists refetch

  // Sessions started elsewhere (the phone, a `vc` on the PC) show up without a
  // manual Refresh: expanded lists refetch on a slow poll while the workspace is
  // on screen, and everything refetches when the window regains focus.
  late final Timer _poll = Timer.periodic(const Duration(seconds: 15), (_) {
    if (mounted && TickerMode.valuesOf(context).enabled) setState(() => _sidebarGen++);
  });
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _refreshSidebar);

  @override
  void initState() {
    super.initState();
    _poll;
    _lifecycle;
    _restore();
  }

  @override
  void dispose() {
    _poll.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _refreshSidebar() => setState(() {
        _projects = _api.projects();
        _presets = _api.presets().catchError((_) => <AgentPreset>[]);
        _sidebarGen++;
      });

  Future<void> _restore() async {
    try {
      final (ids, active) = await WorkspacePrefs.load();
      if (ids.isEmpty) return;
      final byId = {for (final s in await _api.allSessions()) s.id: s};
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          final s = byId[id];
          if (s != null && s.canOpen && _tabs.length < WorkspaceScreen.maxTabs) _add(s);
        }
        _active = _tabs.any((t) => t.id == active) ? active : _tabs.firstOrNull?.id;
      });
      _persist();
    } catch (_) {/* offline at launch — start with no tabs */}
  }

  void _add(Session s) {
    _tabs.add(s);
    _keys[s.id] = GlobalKey();
  }

  void _persist() => WorkspacePrefs.save([for (final t in _tabs) t.id], _active);

  Session? _tab(String? id) => id == null ? null : _tabs.where((t) => t.id == id).firstOrNull;

  void _open(Session s) {
    _scaffoldKey.currentState?.closeDrawer();
    if (_tab(s.id) == null) {
      if (_tabs.length >= WorkspaceScreen.maxTabs) {
        _snack('Close a tab first (max ${WorkspaceScreen.maxTabs}).');
        return;
      }
      _add(s);
    }
    _select(s.id);
  }

  /// Make [id] the left pane. Picking the right pane's tab swaps the two.
  void _select(String id) {
    setState(() {
      if (id == _split) _split = _active;
      _active = id;
    });
    _persist();
  }

  /// Detach only — the daemon session stays live (Close inside the session
  /// deletes it, then calls this).
  void _closeTab(String id) {
    final i = _tabs.indexWhere((t) => t.id == id);
    if (i < 0) return;
    setState(() {
      _tabs.removeAt(i);
      _keys.remove(id);
      _titles.remove(id);
      if (_split == id) _split = null;
      if (_active == id) {
        _active = _split ?? (_tabs.isEmpty ? null : _tabs[i.clamp(0, _tabs.length - 1)].id);
        if (_split == _active) _split = null;
      }
      _sidebarGen++;
    });
    _persist();
  }

  /// Open [s] in the right pane (a new split), keeping the current left pane.
  void _openSplit(Session s) {
    if (_active == null || _active == s.id) return _open(s);
    if (_tab(s.id) == null) {
      if (_tabs.length >= WorkspaceScreen.maxTabs) {
        _snack('Close a tab first (max ${WorkspaceScreen.maxTabs}).');
        return;
      }
      _add(s);
    }
    setState(() => _split = s.id);
    _persist();
  }

  /// Sidebar right-click on a session tile.
  Future<void> _sessionMenu(Session s, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final isOpen = _tab(s.id) != null;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(value: 'split', child: Text('Open in new split')),
        if (isOpen) const PopupMenuItem(value: 'close', child: Text('Close tab')),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
        const PopupMenuItem(value: 'copy', child: Text('Copy session ID')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'kill',
          child: Text('Kill session', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'split':
        _openSplit(s);
      case 'close':
        _closeTab(s.id);
      case 'rename':
        if (await renameSession(context, _api, s)) setState(() => _sidebarGen++);
      case 'tags':
        if (await editSessionTags(context, _api, s)) setState(() => _sidebarGen++);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: s.id));
        _snack('Session ID copied');
      case 'kill':
        if (await killSession(context, _api, s)) {
          _closeTab(s.id); // no-op if it wasn't open
          if (mounted) setState(() => _sidebarGen++);
        }
    }
  }

  /// Drag-reorder in the tab strip. Order only — panes and active/split are
  /// keyed by id, so nothing remounts.
  void _reorder(int from, int to) {
    if (from == to) return;
    setState(() => _tabs.insert(to, _tabs.removeAt(from)));
    _persist();
  }

  void _cycle(int delta) {
    if (_tabs.length < 2) return;
    final i = _tabs.indexWhere((t) => t.id == _active);
    _select(_tabs[(i + delta) % _tabs.length].id);
  }

  /// Compact windows hide the split view and changes pane (state is kept).
  bool get _compact => DesktopShell.isCompact(context);

  void _toggleSplit() {
    if (_compact) return;
    if (_split != null) {
      setState(() => _split = null);
      return;
    }
    final others = _tabs.where((t) => t.id != _active).toList();
    if (others.isEmpty) {
      _snack('Open a second session to split.');
      return;
    }
    final i = _tabs.indexWhere((t) => t.id == _active);
    setState(() => _split = _tabs[(i + 1) % _tabs.length].id);
  }

  /// New session in [p]: a chat (model picked first), a plain terminal, or an
  /// agent CLI terminal ([preset], ADR 0016).
  Future<void> _create(Project p, String kind, {String? preset, bool worktree = false}) async {
    String? model;
    if (kind == 'claude') {
      final choice = await chooseModel(context, _api);
      if (choice == null) return;
      model = choice.id;
    }
    try {
      final s = await _api.create(p.id, kind: kind, model: model, preset: preset, worktree: worktree);
      if (!mounted) return;
      setState(() => _sidebarGen++);
      _open(s);
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _palette() async {
    final s = await showCommandPalette(context, widget.creds);
    if (s != null && mounted) _open(s);
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _retitle(String id, String title) {
    if (mounted && _titles[id] != title) setState(() => _titles[id] = title);
  }

  Widget _page(Session s) => KeyedSubtree(
        key: _keys[s.id],
        child: s.kind == 'claude'
            ? ChatScreen(
                creds: widget.creds,
                session: s,
                onClose: () => _closeTab(s.id),
                onTitle: (t) => _retitle(s.id, t),
                onOpenSession: _open,
              )
            : TerminalScreen(creds: widget.creds, session: s, onClose: () => _closeTab(s.id)),
      );

  Widget _panes() {
    final visible = [_tab(_active), _compact ? null : _tab(_split)].nonNulls.toList();
    if (visible.isEmpty) {
      return const EmptyState(
        icon: Icons.tab_outlined,
        title: 'No session open',
        hint: 'Pick one on the left, or press Ctrl+K.',
      );
    }
    return Stack(fit: StackFit.expand, children: [
      Row(children: [
        for (final (i, s) in visible.indexed) ...[
          if (i > 0) const VerticalDivider(width: 1),
          Expanded(child: _page(s)),
        ],
      ]),
      for (final s in _tabs)
        if (!visible.contains(s)) Visibility(visible: false, maintainState: true, child: _page(s)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final active = _tab(_active);
    final compact = _compact;
    final sidebar = _Sidebar(
      projects: _projects,
      presets: _presets,
      api: _api,
      generation: _sidebarGen,
      openIds: {for (final t in _tabs) t.id},
      onOpen: _open,
      onMenu: _sessionMenu,
      onCreate: _create,
      onNotes: (p) => showProjectNotes(context, widget.creds, p),
      onRefresh: _refreshSidebar,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _palette,
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _cycle(1),
        const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _cycle(-1),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (_active != null) _closeTab(_active!);
        },
        const SingleActivator(LogicalKeyboardKey.backslash, control: true): _toggleSplit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: _scaffoldKey,
          drawer: compact ? Drawer(width: 280, child: SafeArea(child: sidebar)) : null,
          body: Row(children: [
            if (!compact) SizedBox(width: 260, child: sidebar),
            if (!compact) const VerticalDivider(width: 1),
            Expanded(
              child: Column(children: [
                _TabStrip(
                  tabs: _tabs,
                  titles: _titles,
                  active: _active,
                  split: compact ? null : _split,
                  showChanges: _showChanges,
                  compact: compact,
                  onSelect: _select,
                  onClose: _closeTab,
                  onReorder: _reorder,
                  onSplit: _toggleSplit,
                  onPalette: _palette,
                  onSidebar: () => _scaffoldKey.currentState?.openDrawer(),
                  onToggleChanges: () => setState(() => _showChanges = !_showChanges),
                ),
                const Divider(height: 1),
                Expanded(child: _panes()),
              ]),
            ),
            if (!compact && _showChanges && active != null && active.kind == 'claude') ...[
              const VerticalDivider(width: 1),
              SizedBox(
                width: 300,
                child: _ChangesPane(key: ValueKey(active.id), creds: widget.creds, session: active),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

typedef CreateSession = void Function(Project, String kind, {String? preset, bool worktree});
typedef SessionMenu = void Function(Session, Offset globalPosition);

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.projects,
    required this.presets,
    required this.api,
    required this.generation,
    required this.openIds,
    required this.onOpen,
    required this.onMenu,
    required this.onCreate,
    required this.onNotes,
    required this.onRefresh,
  });

  final Future<List<Project>> projects;
  final Future<List<AgentPreset>> presets;
  final SessionApi api;
  final int generation;
  final Set<String> openIds;
  final void Function(Session) onOpen;
  final SessionMenu onMenu;
  final CreateSession onCreate;
  final void Function(Project) onNotes;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      ListTile(
        dense: true,
        title: Text('Projects', style: Theme.of(context).textTheme.titleSmall),
        trailing: IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh, size: 18), onPressed: onRefresh),
      ),
      Expanded(
        child: FutureBuilder<List<Project>>(
          future: projects,
          builder: (context, snap) {
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            if (!snap.hasData) return const SkeletonList(rows: 5);
            return ListView(children: [
              for (final p in snap.data!)
                ExpansionTile(
                  key: PageStorageKey(p.id),
                  dense: true,
                  leading: const Icon(Icons.folder_outlined, size: 18),
                  title: Text(p.label, overflow: TextOverflow.ellipsis),
                  subtitle: p.gitBranch == null ? null : Text(p.gitBranch!, overflow: TextOverflow.ellipsis),
                  children: [
                    _ProjectSessions(
                      key: ValueKey(p.id),
                      generation: generation,
                      project: p,
                      api: api,
                      presets: presets,
                      openIds: openIds,
                      onOpen: onOpen,
                      onMenu: onMenu,
                      onCreate: onCreate,
                      onNotes: onNotes,
                    ),
                  ],
                ),
            ]);
          },
        ),
      ),
    ]);
  }
}

/// A project's openable sessions (live first) plus new-session buttons.
/// Fetched when the tile is first expanded; refetched when [generation] changes,
/// keeping the old list on screen meanwhile (no spinner flash on each poll).
class _ProjectSessions extends StatefulWidget {
  const _ProjectSessions({
    super.key,
    required this.generation,
    required this.project,
    required this.api,
    required this.presets,
    required this.openIds,
    required this.onOpen,
    required this.onMenu,
    required this.onCreate,
    required this.onNotes,
  });

  final int generation;
  final Project project;
  final SessionApi api;
  final Future<List<AgentPreset>> presets;
  final Set<String> openIds;
  final void Function(Session) onOpen;
  final SessionMenu onMenu;
  final CreateSession onCreate;
  final void Function(Project) onNotes;

  @override
  State<_ProjectSessions> createState() => _ProjectSessionsState();
}

class _ProjectSessionsState extends State<_ProjectSessions> {
  late Future<List<Session>> _sessions = _fetch();

  Future<List<Session>> _fetch() => widget.api.sessions(widget.project.id).then(
        (all) => all.where((s) => s.canOpen).toList()..sort((a, b) => (b.isLive ? 1 : 0) - (a.isLive ? 1 : 0)),
      );

  @override
  void didUpdateWidget(_ProjectSessions old) {
    super.didUpdateWidget(old);
    if (old.generation != widget.generation) _sessions = _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Session>>(
      future: _sessions,
      builder: (context, snap) {
        if (snap.hasError) return ErrorBody(message: '${snap.error}');
        if (!snap.hasData) return const LinearProgressIndicator(minHeight: 2);
        return Column(children: [
          for (final s in snap.data!)
            GestureDetector(
              onSecondaryTapUp: (d) => widget.onMenu(s, d.globalPosition),
              child: ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: Spacing.xl, right: Spacing.sm),
                selected: widget.openIds.contains(s.id),
                leading: Icon(
                  s.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal,
                  size: 16,
                  color: s.isLive ? scheme.primary : null,
                ),
                title: Text(s.label, overflow: TextOverflow.ellipsis),
                subtitle: s.externalStatus != null
                    ? const Text('on PC')
                    : (s.worktreeBranch != null ? Text('isolated · ${s.worktreeBranch}', overflow: TextOverflow.ellipsis) : null),
                onTap: () => widget.onOpen(s),
              ),
            ),
          OverflowBar(alignment: MainAxisAlignment.start, children: [
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Chat'),
              onPressed: () => widget.onCreate(widget.project, 'claude'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.call_split, size: 16),
              label: const Text('Isolated chat'),
              onPressed: () => widget.onCreate(widget.project, 'claude', worktree: true),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Terminal'),
              onPressed: () => widget.onCreate(widget.project, 'terminal'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.sticky_note_2_outlined, size: 16),
              label: const Text('Notes'),
              onPressed: () => widget.onNotes(widget.project),
            ),
            FutureBuilder<List<AgentPreset>>(
              future: widget.presets,
              builder: (context, snap) {
                final presets = snap.data ?? const <AgentPreset>[];
                if (presets.isEmpty) return const SizedBox.shrink();
                return PopupMenuButton<AgentPreset>(
                  tooltip: 'Start an agent CLI',
                  onSelected: (p) => widget.onCreate(widget.project, 'terminal', preset: p.id),
                  itemBuilder: (_) => [for (final p in presets) PopupMenuItem(value: p, child: Text(p.label))],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.sm),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add, size: 16),
                      SizedBox(width: Spacing.xs),
                      Text('Agent'),
                    ]),
                  ),
                );
              },
            ),
          ]),
        ]);
      },
    );
  }
}

class _TabStrip extends ConsumerStatefulWidget {
  const _TabStrip({
    required this.tabs,
    required this.titles,
    required this.active,
    required this.split,
    required this.showChanges,
    required this.compact,
    required this.onSelect,
    required this.onClose,
    required this.onReorder,
    required this.onSplit,
    required this.onPalette,
    required this.onSidebar,
    required this.onToggleChanges,
  });

  final List<Session> tabs;
  final Map<String, String> titles; // live title by session id; beats the stale Session.title
  final String? active;
  final String? split;
  final bool showChanges;
  final bool compact; // split + changes disabled, sidebar button shown
  final void Function(String) onSelect;
  final void Function(String) onClose;
  final void Function(int from, int to) onReorder;
  final VoidCallback onSplit;
  final VoidCallback onPalette;
  final VoidCallback onSidebar;
  final VoidCallback onToggleChanges;

  @override
  ConsumerState<_TabStrip> createState() => _TabStripState();
}

/// Tabs shrink to fit (label down to [_minLabel]); past that the strip
/// scrolls — mouse wheel, scrollbar — and keeps the active tab in view.
class _TabStripState extends ConsumerState<_TabStrip> {
  static const _maxLabel = 160.0;
  static const _minLabel = 40.0;
  static const _chrome = 76.0; // avatar + close icon + chip padding + outer padding, per tab

  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  @override
  void didUpdateWidget(_TabStrip old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active || old.tabs.length != widget.tabs.length) _revealActive();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the active tab into view. Every tab has the same width, so its
  /// extent is the content length split evenly.
  void _revealActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final i = widget.tabs.indexWhere((s) => s.id == widget.active);
      if (!mounted || !_scroll.hasClients || i < 0) return;
      final p = _scroll.position;
      final extent = (p.maxScrollExtent + p.viewportDimension - 2 * Spacing.xs) / widget.tabs.length;
      final start = Spacing.xs + i * extent;
      final end = start + extent;
      double? to;
      if (start < p.pixels) {
        to = start - Spacing.xs;
      } else if (end > p.pixels + p.viewportDimension) {
        to = end - p.viewportDimension + Spacing.xs;
      }
      if (to != null) {
        _scroll.animateTo(to.clamp(0, p.maxScrollExtent), duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  /// A vertical mouse wheel doesn't move a horizontal list on desktop; map it.
  void _onWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || e.scrollDelta.dy == 0 || !_scroll.hasClients) return;
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + e.scrollDelta.dy).clamp(0, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tabs = w.tabs;
    final titles = w.titles;
    final active = w.active;
    final split = w.split;
    final scheme = Theme.of(context).colorScheme;
    final attention = ref.watch(sessionAttentionProvider);
    return SizedBox(
      height: 44,
      child: Row(children: [
        if (w.compact) IconButton(tooltip: 'Projects', icon: const Icon(Icons.menu), onPressed: w.onSidebar),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final fit = tabs.isEmpty ? _maxLabel : (box.maxWidth - 2 * Spacing.xs) / tabs.length - _chrome;
            final label = fit.clamp(_minLabel, _maxLabel);
            final overflow = fit < _minLabel;
            return Listener(
              onPointerSignal: _onWheel,
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: overflow,
                // Drag a tab to move it; a plain click still selects (the drag only
                // starts past touch slop). No separate handles — browser-style.
                child: ReorderableListView(
                  scrollController: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                  buildDefaultDragHandles: false,
                  onReorderItem: w.onReorder,
                  children: [
                    for (final (i, s) in tabs.indexed)
                      ReorderableDragStartListener(
                        key: ValueKey(s.id),
                        index: i,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                          child: InputChip(
                            selected: s.id == active || s.id == split,
                            showCheckmark: false,
                            avatar: FlashingBadge(
                              count: attention.containsKey(s.id) ? 1 : 0,
                              showCount: false,
                              child: Icon(s.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal, size: 16),
                            ),
                            // Fixed width so every tab is the same size (lets
                            // _revealActive compute offsets without measuring).
                            label: SizedBox(
                              width: label,
                              child: Text(titles[s.id] ?? s.label, overflow: TextOverflow.ellipsis),
                            ),
                            side: attention.containsKey(s.id)
                                ? BorderSide(color: scheme.error)
                                : s.id == active
                                    ? BorderSide(color: scheme.primary)
                                    : null,
                            tooltip: switch (attention[s.id]) {
                              Attention.needsInput => 'Waiting for you',
                              Attention.done => 'Finished — waiting for next steps',
                              null => titles[s.id] ?? s.label, // shrunk labels cut the title short
                            },
                            onPressed: () => w.onSelect(s.id),
                            onDeleted: () => w.onClose(s.id),
                            deleteButtonTooltipMessage: 'Close tab (session keeps running)',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
        IconButton(tooltip: 'Open session (Ctrl+K)', icon: const Icon(Icons.search), onPressed: w.onPalette),
        IconButton(
          tooltip: 'Split (Ctrl+\\)',
          isSelected: split != null,
          icon: const Icon(Icons.vertical_split_outlined),
          onPressed: w.compact ? null : w.onSplit,
        ),
        IconButton(
          tooltip: 'Changed files',
          isSelected: w.showChanges,
          icon: const Icon(Icons.difference_outlined),
          onPressed: w.compact ? null : w.onToggleChanges,
        ),
      ]),
    );
  }
}

/// Right pane: the project's git summary plus the active chat's changed files.
class _ChangesPane extends StatefulWidget {
  const _ChangesPane({super.key, required this.creds, required this.session});
  final Creds creds;
  final Session session;

  @override
  State<_ChangesPane> createState() => _ChangesPaneState();
}

class _ChangesPaneState extends State<_ChangesPane> {
  late final _dio = dioFor(widget.creds);
  late Future<GitStatus> _git = GitApi(_dio).status(widget.session.projectId);
  int _gen = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        dense: true,
        title: FutureBuilder<GitStatus>(
          future: _git,
          builder: (context, snap) => Text(
            snap.data?.summary ?? (snap.hasError ? 'git status unavailable' : '…'),
            style: theme.textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: () => setState(() {
            _git = GitApi(_dio).status(widget.session.projectId);
            _gen++;
          }),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ChangedFilesList(
          key: ValueKey(_gen),
          api: FileEditsApi(_dio),
          creds: widget.creds,
          session: widget.session,
        ),
      ),
    ]);
  }
}
