import 'package:flutter/material.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../data/task_api.dart';
import '../domain/merge_item.dart';
import '../domain/task.dart';
import 'merge_approval_screen.dart';
import 'project_settings_dialog.dart';

/// Opens a project's swarm tasks (proposal 65): a bottom sheet on mobile, a dialog
/// on desktop.
Future<void> showProjectTasks(BuildContext context, Creds creds, Project project) {
  final panel = TasksPanel(creds: creds, project: project);
  if (isMobile) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.8, child: panel),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 560, height: 640, child: panel)),
  );
}

class TasksPanel extends StatefulWidget {
  const TasksPanel({super.key, required this.creds, required this.project, this.api});
  final Creds creds;
  final Project project;

  /// Tests inject a fake; the app builds one from [creds].
  final TaskApi? api;

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel> {
  late final TaskApi _api = widget.api ?? TaskApi(dioFor(widget.creds));
  List<Task>? _tasks;
  Map<String, MergeItem> _queue = const {}; // latest queue item per task id
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tasks = await _api.list(widget.project.id);
      // The queue is secondary: a failure (e.g. 503 without VIBE_MERGE_DIR) must not hide the tasks.
      var queue = _queue;
      try {
        queue = latestByTask(await _api.listQueue(widget.project.id));
      } catch (_) {}
      if (mounted) {
        setState(() {
          _tasks = tasks;
          _queue = queue;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _say(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // Run a server action, then re-read the list (the daemon owns the state machine).
  Future<void> _act(String failed, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      _say('$failed: $e');
    }
    await _load();
  }

  Future<void> _dispatch(Task t) => _act('Could not dispatch', () async {
        await _api.dispatch(t.id);
        _say('Started a session for "${t.title}"'); // the refresh shows it running; Open session jumps to it
      });

  Future<void> _enqueue(Task t) => _act('Could not merge', () async {
        await _api.enqueue(t.id);
        _say('"${t.title}" queued for merge');
      });

  Future<void> _openMerge(Task t, MergeItem item) async {
    await showMergeApproval(context, _api, item, taskTitle: t.title);
    await _load();
  }

  Future<void> _openSession(Task t) async {
    final id = t.sessionId;
    if (id == null) return;
    try {
      final s = await SessionApi(dioFor(widget.creds)).get(id);
      if (s == null) {
        _say('That session no longer exists');
        return;
      }
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(); // close the tasks sheet / dialog
      nav.push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: s)));
    } catch (e) {
      _say('Could not open the session: $e');
    }
  }

  Future<void> _setState(Task t, String state) => _act('Could not update', () async {
        await _api.update(t.id, state: state);
      });

  Future<void> _delete(Task t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text(t.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _act('Could not delete', () => _api.delete(t.id));
  }

  Future<void> _form([Task? existing]) async {
    final result = await showDialog<_TaskDraft>(
      context: context,
      builder: (ctx) => _TaskForm(existing: existing, others: [...?_tasks].where((x) => x.id != existing?.id).toList()),
    );
    if (result == null) return;
    await _act('Task not saved', () async {
      if (existing == null) {
        await _api.create(widget.project.id, title: result.title, body: result.body, scope: result.scope, deps: result.deps);
      } else {
        await _api.update(existing.id, title: result.title, body: result.body, scope: result.scope, deps: result.deps);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.sm, Spacing.sm, 0),
        child: Row(children: [
          Expanded(
            child: Text('Tasks · ${widget.project.label}',
                style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            tooltip: 'Project settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showProjectSettings(context, _api, widget.project),
          ),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New task'),
            onPressed: _tasks == null ? null : () => _form(),
          ),
        ]),
      ),
      Expanded(child: _body(theme)),
    ]);
  }

  Widget _body(ThemeData theme) {
    if (_error != null) return ErrorBody(message: _error!);
    final tasks = _tasks;
    if (tasks == null) return const SkeletonList(rows: 4);
    if (tasks.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [
          EmptyState(
            icon: Icons.task_alt_outlined,
            title: 'No tasks yet',
            hint: 'Split work into tasks with a file scope, then dispatch each to its own session.',
          ),
        ]),
      );
    }
    final titles = {for (final t in tasks) t.id: t.title};
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        for (final (state, group) in groupByState(tasks)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, Spacing.xs),
            child: Text('${state[0].toUpperCase()}${state.substring(1)} · ${group.length}',
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          for (final t in group) _row(theme, t, titles),
        ],
      ]),
    );
  }

  Widget _row(ThemeData theme, Task t, Map<String, String> titles) {
    final sub = [
      if (t.scope.isNotEmpty) 'Scope: ${t.scope.join(', ')}',
      if (t.deps.isNotEmpty) 'After: ${t.deps.map((d) => titles[d] ?? d).join(', ')}',
    ].join('\n');
    return ListTile(
      dense: true,
      title: Text(t.title),
      subtitle: sub.isEmpty ? null : Text(sub, maxLines: 3, overflow: TextOverflow.ellipsis),
      onTap: t.state == 'ready' ? () => _form(t) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (_queue[t.id] case final item?) MergeBadge(item: item, onTap: () => _openMerge(t, item)),
        PopupMenuButton<String>(
        tooltip: 'Task actions',
        onSelected: (a) {
          switch (a) {
            case 'dispatch':
              _dispatch(t);
            case 'open':
              _openSession(t);
            case 'merge':
              _enqueue(t);
            case 'done':
              _setState(t, 'done');
            case 'ready':
              _setState(t, 'ready');
            case 'delete':
              _delete(t);
          }
        },
        itemBuilder: (_) => [
          if (t.state == 'ready') const PopupMenuItem(value: 'dispatch', child: Text('Dispatch')),
          if (t.sessionId != null) const PopupMenuItem(value: 'open', child: Text('Open session')),
          if (t.state == 'review' && !_queue.containsKey(t.id)) const PopupMenuItem(value: 'merge', child: Text('Merge')),
          if (t.state == 'review') const PopupMenuItem(value: 'done', child: Text('Mark done')),
          if (t.state != 'ready') const PopupMenuItem(value: 'ready', child: Text('Back to ready')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
        ),
      ]),
    );
  }
}

class _TaskDraft {
  _TaskDraft(this.title, this.body, this.scope, this.deps);
  final String title;
  final String body;
  final List<String> scope;
  final List<String> deps;
}

class _TaskForm extends StatefulWidget {
  const _TaskForm({this.existing, required this.others});
  final Task? existing;
  final List<Task> others;

  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? '');
  late final _scope = TextEditingController(text: scopeText(widget.existing?.scope ?? const []));
  late final Set<String> _deps = {...?widget.existing?.deps};

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New task' : 'Edit task'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: _title,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Title', counterText: ''),
            ),
            const SizedBox(height: Spacing.sm),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Goal and acceptance criteria'),
            ),
            const SizedBox(height: Spacing.sm),
            TextField(
              controller: _scope,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Scope (one path per line)',
                helperText: 'Files or folders only this task may change, e.g. src/auth',
              ),
            ),
            if (widget.others.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Text('Depends on', style: Theme.of(context).textTheme.labelLarge),
              Wrap(spacing: Spacing.xs, children: [
                for (final o in widget.others)
                  FilterChip(
                    label: Text(o.title, overflow: TextOverflow.ellipsis),
                    selected: _deps.contains(o.id),
                    onSelected: (v) => setState(() => v ? _deps.add(o.id) : _deps.remove(o.id)),
                  ),
              ]),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(context, _TaskDraft(title, _body.text, parseScope(_scope.text), _deps.toList()));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
