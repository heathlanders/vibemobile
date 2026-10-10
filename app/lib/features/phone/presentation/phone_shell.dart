import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/session_attention.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../projects/presentation/new_project_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/presentation/model_picker.dart';
import '../../sessions/presentation/session_search_screen.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/phone_prefs.dart';
import 'phone_panel.dart';
import 'you_screen.dart';

/// Phone navigation, modelled on Discord mobile (proposal 54): the open session
/// fills the screen; swiping right or tapping the menu button slides it aside
/// to reveal the project rail + session list, with a bottom bar while it's open.
class PhoneShell extends ConsumerStatefulWidget {
  const PhoneShell({super.key, required this.creds});
  final Creds creds;

  /// How much of the content stays visible at the right edge while the panel is open.
  static const peek = 56.0;

  @override
  ConsumerState<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends ConsumerState<PhoneShell> with SingleTickerProviderStateMixin {
  static const _barHeight = 64.0;

  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final AnimationController _slide = AnimationController(vsync: this, value: 1); // 1 = panel open
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _refresh);

  bool _open = true;
  double _range = 1; // content travel in px, set by LayoutBuilder
  List<Project>? _projects;
  List<Session> _sessions = const [];
  List<AgentPreset> _presets = const [];
  String? _error;
  String _selected = phoneLiveId; // until the project list arrives
  String? _lastProject;
  Session? _session;
  final _titles = <String, String>{};

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _init();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _slide.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final (projectId, sessionId) = await PhonePrefs.load();
    await _fetch();
    if (!mounted) return;
    final projects = _projects;
    if (projects == null) return;
    setState(() {
      final sorted = _sorted(projects);
      _selected = projects.any((p) => p.id == projectId) ? projectId! : (sorted.firstOrNull?.id ?? phoneLiveId);
      _lastProject = _selected == phoneLiveId ? null : _selected;
      _session ??= _sessions.where((s) => s.id == sessionId && s.canOpen).firstOrNull;
    });
    _api
        .presets()
        .then((p) {
          if (mounted) setState(() => _presets = p);
        })
        .catchError((_) {});
  }

  /// Most recently touched first; projects with no timestamp sink to the end.
  List<Project> _sorted(List<Project> ps) => [...ps]
    ..sort((a, b) {
      final x = a.lastActive, y = b.lastActive;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });

  Future<void> _fetch() async {
    try {
      final projects = await _api.projects();
      final sessions = await _api.allSessions();
      if (!mounted) return;
      setState(() {
        _projects = _sorted(projects);
        _sessions = sessions;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _refresh() => _fetch();

  void _setOpen(bool open) {
    if (open) _fetch();
    setState(() => _open = open);
    _slide.animateTo(open ? 1 : 0, duration: Motion.base, curve: open ? Motion.enter : Motion.exit);
  }

  void _select(String id) {
    setState(() => _selected = id);
    if (id != phoneLiveId) {
      _lastProject = id;
      PhonePrefs.saveProject(id);
    }
  }

  void _openSession(Session s) {
    setState(() => _session = s);
    PhonePrefs.saveSession(s.id);
    _setOpen(false);
  }

  void _closeSession(String id) {
    if (_session?.id != id) return;
    setState(() => _session = null);
    PhonePrefs.saveSession(null);
    _setOpen(true);
  }

  void _retitle(String id, String title) {
    if (mounted && _titles[id] != title) setState(() => _titles[id] = title);
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// New session in the selected project: a chat (model picked first), a plain
  /// terminal, or an agent CLI terminal (ADR 0016).
  Future<void> _create(String kind, {String? preset, bool worktree = false}) async {
    if (_selected == phoneLiveId) return;
    String? model;
    if (kind == 'claude') {
      final choice = await chooseModel(context, _api);
      if (choice == null) return;
      model = choice.id;
    }
    try {
      final s = await _api.create(_selected, kind: kind, model: model, preset: preset, worktree: worktree);
      if (!mounted) return;
      _fetch();
      _openSession(s);
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _newProject() async {
    final project = await Navigator.of(context).push<Project>(sharedAxisRoute(NewProjectScreen(creds: widget.creds)));
    if (project == null || !mounted) return;
    await _fetch();
    if (mounted) _select(project.id);
  }

  void _push(Widget screen) => Navigator.of(context).push(sharedAxisRoute(screen));

  void _onBar(int i) {
    switch (i) {
      case 0:
        if (_selected == phoneLiveId && _lastProject != null) _select(_lastProject!);
      case 1:
        _select(phoneLiveId);
      case 2:
        _push(SessionSearchScreen(creds: widget.creds));
      case 3:
        _push(YouScreen(creds: widget.creds));
    }
  }

  Widget _content() {
    final s = _session;
    if (s == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: () => _setOpen(true)),
        ),
        body: const EmptyState(icon: Icons.chat_bubble_outline, title: 'Pick a session', hint: 'Swipe right or tap ☰'),
      );
    }
    void onMenu() => _setOpen(true);
    return s.kind == 'claude'
        ? ChatScreen(
            key: ValueKey(s.id),
            creds: widget.creds,
            session: s,
            onClose: () => _closeSession(s.id),
            onTitle: (t) => _retitle(s.id, t),
            onOpenSession: _openSession,
            onMenu: onMenu,
          )
        : TerminalScreen(
            key: ValueKey(s.id),
            creds: widget.creds,
            session: s,
            onClose: () => _closeSession(s.id),
            onMenu: onMenu,
          );
  }

  void _drag(DragUpdateDetails d) => _slide.value += (d.primaryDelta ?? 0) / _range;

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    _setOpen(v.abs() > 700 ? v > 0 : _slide.value > 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final attention = ref.watch(sessionAttentionProvider);
    return PopScope(
      // Back with a session showing opens the panel; back on the panel leaves the app.
      canPop: _open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setOpen(true);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(
          builder: (context, box) {
            _range = box.maxWidth - PhoneShell.peek;
            final bottom = MediaQuery.paddingOf(context).bottom;
            return AnimatedBuilder(
              animation: _slide,
              builder: (context, _) {
                final v = _slide.value;
                return Stack(
                  children: [
                    Offstage(
                      offstage: v == 0,
                      // Swipe left on the panel itself closes it too.
                      child: GestureDetector(
                        onHorizontalDragUpdate: _drag,
                        onHorizontalDragEnd: _dragEnd,
                        child: Padding(
                          padding: EdgeInsets.only(right: PhoneShell.peek, bottom: _barHeight + bottom),
                          child: PhonePanel(
                            projects: _projects,
                            sessions: _sessions,
                            error: _error,
                            selected: _selected,
                            titles: _titles,
                            presets: _presets,
                            activeSessionId: _session?.id,
                            onSelect: _select,
                            onOpen: _openSession,
                            onCreate: _create,
                            onNewProject: _newProject,
                            onRefresh: _refresh,
                          ),
                        ),
                      ),
                    ),
                    Transform.translate(
                      offset: Offset(v * _range, 0),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: v > 0 ? () => _setOpen(false) : null,
                        onHorizontalDragUpdate: _drag,
                        onHorizontalDragEnd: _dragEnd,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border(left: BorderSide(color: scheme.outlineVariant)),
                          ),
                          child: IgnorePointer(ignoring: v > 0, child: _content()),
                        ),
                      ),
                    ),
                    if (v > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: FractionalTranslation(
                          translation: Offset(0, 1 - v),
                          child: NavigationBar(
                            height: _barHeight,
                            selectedIndex: _selected == phoneLiveId ? 1 : 0,
                            onDestinationSelected: _onBar,
                            destinations: [
                              const NavigationDestination(
                                icon: Icon(Icons.home_outlined),
                                selectedIcon: Icon(Icons.home),
                                label: 'Home',
                              ),
                              NavigationDestination(
                                icon: FlashingBadge(count: attention.length, child: const Icon(Icons.bolt_outlined)),
                                selectedIcon: FlashingBadge(count: attention.length, child: const Icon(Icons.bolt)),
                                label: 'Live',
                              ),
                              const NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
                              const NavigationDestination(
                                icon: Icon(Icons.person_outline),
                                selectedIcon: Icon(Icons.person),
                                label: 'You',
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
