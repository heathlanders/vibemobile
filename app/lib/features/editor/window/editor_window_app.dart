import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_log.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/theme_controller.dart';
import '../../../core/widgets.dart';
import '../../files/data/project_files_api.dart';
import '../presentation/code_editor_screen.dart';
import '../presentation/editor_controller.dart';
import 'editor_ipc.dart';
import 'editor_native.dart';
import 'editor_tabs.dart';

/// Entry for `vibemobile.exe --editor` (proposal 62): the one editor window. No push, no update
/// checks. Exits quietly when another editor already holds the lock; that one gets the request.
Future<void> runEditorWindow() async {
  final ipc = await EditorIpc.forApp();
  if (!ipc.acquireLock()) {
    AppLog.info('editor: already running, exiting');
    exit(0);
  }
  runApp(ProviderScope(child: EditorWindowApp(ipc: ipc)));
}

class EditorWindowApp extends ConsumerWidget {
  const EditorWindowApp({super.key, required this.ipc});
  final EditorIpc ipc;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        title: EditorNative.windowTitle,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ref.watch(themeModeProvider),
        builder: AppTheme.capToastWidth,
        home: EditorWindowHome(ipc: ipc),
      );
}

class EditorWindowHome extends ConsumerStatefulWidget {
  const EditorWindowHome({super.key, required this.ipc});
  final EditorIpc ipc;

  @override
  ConsumerState<EditorWindowHome> createState() => _EditorWindowHomeState();
}

class _EditorWindowHomeState extends ConsumerState<EditorWindowHome> {
  late final EditorTabs _tabs = EditorTabs(isDirty: _isDirty);
  final _lines = <String, int>{}; // 1-based jump target for a tab's first show
  Dio? _dio;
  StreamSubscription<void>? _watch;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);

  EditorTarget? _target(EditorTabRef t) {
    final dio = _dio;
    return dio == null ? null : EditorTarget(ProjectFilesApi(dio, t.scope), t.path, line: _lines[t.id]);
  }

  bool _isDirty(EditorTabRef t) {
    final target = _target(t);
    return target != null && ProviderScope.containerOf(context).read(editorDocProvider(target)).dirty;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _tabs.load(widget.ipc.tabsFile);
    _watch = widget.ipc.watch(_onRequest);
  }

  @override
  void dispose() {
    _watch?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _persist() => _tabs.save(widget.ipc.tabsFile);

  Future<void> _onRequest(EditorRequest r) async {
    var creds = await ref.read(credsProvider.future);
    if (creds == null) {
      ref.invalidate(credsProvider); // maybe paired since
      creds = await ref.read(credsProvider.future);
    }
    if (!mounted) return;
    if (r.quit) return _quit();
    if (creds == null) return;
    _dio ??= dioFor(creds);
    EditorNative.bringToFront();
    final t = EditorTabRef(r.scope!, r.path!);
    final outcome = _tabs.open(t);
    if (outcome == EditorOpenOutcome.full) {
      _say('Close a tab first (max ${_tabs.max}); every open file has unsaved changes.');
      return;
    }
    if (r.line != null && outcome != EditorOpenOutcome.focused) _lines[t.id] = r.line!;
    setState(() {});
    _persist();
  }

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  bool get _anyDirty => _tabs.tabs.any(_isDirty);

  Future<bool> _confirmDiscard(String title) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    return discard == true;
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (!_anyDirty || await _confirmDiscard('Discard unsaved changes in open files?')) return AppExitResponse.exit;
    return AppExitResponse.cancel;
  }

  /// The updater asked us to go away.
  Future<void> _quit() async {
    if (_anyDirty && !await _confirmDiscard('Quit the editor and discard unsaved changes?')) return;
    ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  Future<void> _close(EditorTabRef t) async {
    if (_isDirty(t) && !await _confirmDiscard('Discard unsaved changes to ${t.name}?')) return;
    if (!mounted) return;
    setState(() {
      _tabs.close(t);
      _lines.remove(t.id);
    });
    _persist();
  }

  void _select(EditorTabRef t) {
    setState(() => _tabs.active = t);
    _persist();
  }

  void _cycle(int delta) {
    setState(() => _tabs.cycle(delta));
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final creds = ref.watch(credsProvider);
    final c = creds.value;
    if (c != null) _dio ??= dioFor(c);
    if (creds.hasValue && c == null) {
      return const Scaffold(body: EmptyState(icon: Icons.link_off, title: 'Not paired', hint: 'Pair in the main VibeMobile window'));
    }
    if (_dio == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final tabs = _tabs.tabs;
    final active = _tabs.active;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (active != null) _close(active);
        },
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _cycle(1),
        const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () => _cycle(-1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(children: [
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                children: [
                  for (final t in tabs)
                    _TabChip(key: ValueKey(t.id), tab: t, target: _target(t)!, selected: t == active, onSelect: () => _select(t), onClose: () => _close(t)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: tabs.isEmpty
                  ? const EmptyState(icon: Icons.description_outlined, title: 'No files open', hint: 'Open a file from the main VibeMobile window')
                  : IndexedStack(
                      index: active == null ? 0 : tabs.indexOf(active).clamp(0, tabs.length - 1),
                      children: [
                        for (final t in tabs)
                          CodeEditorScreen(key: ValueKey(t.id), api: _target(t)!.api, path: t.path, line: _lines[t.id], embedded: true),
                      ],
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One tab chip, same look as the workspace's file chips (dirty dot, tooltip = path).
class _TabChip extends ConsumerWidget {
  const _TabChip({super.key, required this.tab, required this.target, required this.selected, required this.onSelect, required this.onClose});
  final EditorTabRef tab;
  final EditorTarget target;
  final bool selected;
  final VoidCallback onSelect, onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dirty = ref.watch(editorDocProvider(target).select((d) => d.dirty));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: Spacing.xs),
      child: InputChip(
        selected: selected,
        showCheckmark: false,
        avatar: const Icon(Icons.description_outlined, size: 16),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(tab.name, overflow: TextOverflow.ellipsis)),
            if (dirty) ...[
              const SizedBox(width: Spacing.xs),
              Container(key: const ValueKey('tab-dirty-dot'), width: 7, height: 7, decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle)),
            ],
          ]),
        ),
        side: selected ? BorderSide(color: scheme.primary) : null,
        tooltip: tab.path,
        onPressed: onSelect,
        onDeleted: onClose,
        deleteButtonTooltipMessage: 'Close file',
      ),
    );
  }
}
