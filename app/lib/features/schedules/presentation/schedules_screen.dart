import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../data/schedule_api.dart';
import '../domain/schedule_info.dart';
import 'schedule_edit_screen.dart';

/// Scheduled tasks (proposal 44): prompts the server runs on its own, on a timetable.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, required this.creds, this.api, this.loadProjects, this.openSession});
  final Creds creds;

  /// Tests inject fakes; production builds them from [creds].
  final ScheduleApi? api;
  final Future<List<Project>> Function()? loadProjects;
  final Future<void> Function(BuildContext context, String sessionId)? openSession;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  late final ScheduleApi _api = widget.api ?? ScheduleApi(dioFor(widget.creds));
  SchedulesData? _data;
  String? _error;
  bool _busy = false;

  Future<List<Project>> _projects() => (widget.loadProjects ?? SessionApi(dioFor(widget.creds)).projects)();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.list();
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _guard(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([ScheduleInfo? s]) async {
    final d = _data;
    if (d == null) return;
    final saved = await Navigator.of(context).push<bool>(sharedAxisRoute(
      ScheduleEditScreen(api: _api, loadProjects: _projects, offsetMin: d.offsetMin, tz: d.tz, existing: s),
    ));
    if (saved == true) await _load();
  }

  Future<void> _delete(ScheduleInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this task?'),
        content: Text('“${s.title}” will stop running. Chats it already started are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _guard(() => _api.delete(s.id));
  }

  Future<void> _openRun(ScheduleInfo s) async {
    final id = s.lastSessionId;
    if (id == null) return;
    if (widget.openSession != null) return widget.openSession!(context, id);
    final session = await SessionApi(dioFor(widget.creds)).get(id);
    if (!mounted) return;
    if (session == null) return _snack('That chat no longer exists.');
    await Navigator.of(context).push(sharedAxisRoute(ChatScreen(creds: widget.creds, session: session)));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled tasks')),
      floatingActionButton: d == null ? null : FloatingActionButton.extended(onPressed: _busy ? null : _edit, icon: const Icon(Icons.add), label: const Text('New task')),
      body: d == null
          ? (_error != null ? ErrorBody(message: _error!) : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.all(Spacing.lg),
                  child: Text(
                    'These run on the server by themselves${d.tz.isEmpty ? '' : ', in its time zone (${d.tz})'}. '
                    'Each run is a normal chat — in Ask mode it waits for your approval and sends you a notification.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (d.schedules.isEmpty)
                  const Padding(padding: EdgeInsets.all(Spacing.xl), child: Center(child: Text('No scheduled tasks yet.')))
                else
                  for (final s in d.schedules) _tile(s, d, theme),
              ]),
            ),
    );
  }

  Widget _tile(ScheduleInfo s, SchedulesData d, ThemeData theme) {
    final next = s.nextRunAt == null ? null : formatServerTime(s.nextRunAt!, d.offsetMin);
    final scheme = theme.colorScheme;
    return ListTile(
      isThreeLine: true,
      title: Row(children: [
        Expanded(child: Text(s.title, overflow: TextOverflow.ellipsis)),
        if (s.isAuto) Padding(padding: const EdgeInsets.only(left: 6), child: Chip(label: const Text('Auto'), visualDensity: VisualDensity.compact, backgroundColor: scheme.errorContainer)),
      ]),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: '${s.projectName ?? s.projectId} · ${s.whenLabel(d.offsetMin)}\n'),
        TextSpan(text: s.enabled ? (next == null ? 'Finished' : 'Next: $next') : 'Paused'),
        if (s.lastStatus != null)
          TextSpan(
            text: '\nLast: ${s.lastStatus}',
            style: TextStyle(color: s.needsAttention ? scheme.error : scheme.onSurfaceVariant),
          ),
      ])),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Switch(value: s.enabled, onChanged: _busy ? null : (v) => _guard(() => _api.update(s.id, {'enabled': v}))),
        PopupMenuButton<String>(
          tooltip: 'Actions',
          onSelected: (a) {
            switch (a) {
              case 'run':
                _guard(() async {
                  await _api.runNow(s.id);
                  _snack('Started. You\'ll be notified if it needs you.');
                });
              case 'edit':
                _edit(s);
              case 'open':
                _openRun(s);
              case 'delete':
                _delete(s);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'run', child: Text('Run now')),
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            if (s.lastSessionId != null) const PopupMenuItem(value: 'open', child: Text('Open last run')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ]),
      onTap: _busy ? null : () => _edit(s),
    );
  }
}
