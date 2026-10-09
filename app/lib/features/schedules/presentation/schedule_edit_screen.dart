import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../../sessions/domain/session.dart';
import '../data/schedule_api.dart';
import '../domain/schedule_info.dart';

/// What the editor sends. Pure → tested. Create includes the project; a patch omits it.
Map<String, Object?> buildScheduleBody({
  String? projectId,
  required String title,
  required String prompt,
  required String mode,
  required bool daily,
  required TimeOfDay time,
  required Set<int> days,
  DateTime? onceDate,
  required int offsetMin,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  return {
    'projectId': ?projectId,
    'title': title.trim(),
    'prompt': prompt,
    'mode': mode,
    'kind': daily ? 'daily' : 'once',
    if (daily) 'time': '${two(time.hour)}:${two(time.minute)}',
    // none or all seven ticked = every day
    if (daily) 'days': (days.isEmpty || days.length == 7) ? null : (days.toList()..sort()),
    if (!daily && onceDate != null)
      'runAt': fromServerLocal(onceDate.year, onceDate.month, onceDate.day, time.hour, time.minute, offsetMin).toIso8601String(),
  };
}

/// Create or edit a scheduled prompt (proposal 44).
class ScheduleEditScreen extends StatefulWidget {
  const ScheduleEditScreen({super.key, required this.api, required this.loadProjects, required this.offsetMin, required this.tz, this.existing});
  final ScheduleApi api;
  final Future<List<Project>> Function() loadProjects;
  final int offsetMin;
  final String tz;
  final ScheduleInfo? existing;

  @override
  State<ScheduleEditScreen> createState() => _ScheduleEditScreenState();
}

class _ScheduleEditScreenState extends State<ScheduleEditScreen> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
  List<Project>? _projects;
  String? _projectId;
  late String _mode = widget.existing?.mode ?? 'ask';
  late bool _daily = (widget.existing?.kind ?? 'daily') == 'daily';
  late TimeOfDay _time = _initialTime();
  late final Set<int> _days = {...?widget.existing?.days};
  DateTime? _onceDate;
  bool _saving = false;
  String? _error;

  TimeOfDay _initialTime() {
    final t = widget.existing?.time;
    if (t != null && t.length == 5) return TimeOfDay(hour: int.tryParse(t.substring(0, 2)) ?? 9, minute: int.tryParse(t.substring(3)) ?? 0);
    final r = widget.existing?.runAt;
    if (r != null) {
      final l = toServerLocal(r, widget.offsetMin);
      return TimeOfDay(hour: l.hour, minute: l.minute);
    }
    return const TimeOfDay(hour: 9, minute: 0);
  }

  @override
  void initState() {
    super.initState();
    _projectId = widget.existing?.projectId;
    final r = widget.existing?.runAt;
    if (r != null) {
      final l = toServerLocal(r, widget.offsetMin);
      _onceDate = DateTime(l.year, l.month, l.day);
    }
    widget.loadProjects().then((p) {
      if (mounted) {
        setState(() {
          _projects = p;
          _projectId ??= p.isEmpty ? null : p.first.id;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _projects = const []);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty && _prompt.text.trim().isNotEmpty && _projectId != null && (_daily || _onceDate != null);

  Future<bool> _confirmAuto() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Run without asking?'),
          content: const Text(
            'In Auto mode this task can edit files and run commands on the server by itself, '
            'while you are not watching. Use it only for prompts you fully trust. '
            'Ask mode waits for your approval on your phone instead.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Ask')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Use Auto')),
          ],
        ),
      ) ??
      false;

  Future<void> _save() async {
    if (_mode == 'auto' && widget.existing?.mode != 'auto' && !await _confirmAuto()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = buildScheduleBody(
      projectId: widget.existing == null ? _projectId : null,
      title: _title.text,
      prompt: _prompt.text,
      mode: _mode,
      daily: _daily,
      time: _time,
      days: _days,
      onceDate: _onceDate,
      offsetMin: widget.offsetMin,
    );
    try {
      if (widget.existing == null) {
        await widget.api.create(body);
      } else {
        await widget.api.update(widget.existing!.id, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    const dayLabels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New scheduled task' : 'Edit scheduled task'),
        actions: [TextButton(onPressed: _valid && !_saving ? _save : null, child: const Text('Save'))],
      ),
      body: ListView(padding: const EdgeInsets.all(Spacing.lg), children: [
        // At the TOP: a refused save must be visible without scrolling past the form.
        if (_saving) const Padding(padding: EdgeInsets.only(bottom: Spacing.md), child: LinearProgressIndicator()),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.md),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        TextField(controller: _title, onChanged: (_) => setState(() {}), maxLength: 120, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: Spacing.sm),
        if (widget.existing == null)
          DropdownButtonFormField<String>(
            initialValue: _projectId,
            decoration: const InputDecoration(labelText: 'Project', border: OutlineInputBorder()),
            items: [for (final p in _projects ?? const <Project>[]) DropdownMenuItem(value: p.id, child: Text(p.label, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _projectId = v),
          )
        else
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Project', border: OutlineInputBorder()),
            child: Text(widget.existing!.projectName ?? widget.existing!.projectId),
          ),
        const SizedBox(height: Spacing.sm),
        TextField(
          controller: _prompt,
          onChanged: (_) => setState(() {}),
          minLines: 4,
          maxLines: 10,
          maxLength: 8000,
          decoration: const InputDecoration(labelText: 'Prompt', alignLabelWithHint: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: Spacing.md),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('Repeats')), ButtonSegment(value: false, label: Text('Once'))],
          selected: {_daily},
          onSelectionChanged: (s) => setState(() => _daily = s.first),
        ),
        const SizedBox(height: Spacing.sm),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule),
          title: Text('At ${_time.format(context)}'),
          subtitle: Text('Server time${widget.tz.isEmpty ? '' : ' (${widget.tz})'}', style: muted),
          onTap: () async {
            final t = await showTimePicker(context: context, initialTime: _time);
            if (t != null) setState(() => _time = t);
          },
        ),
        if (_daily) ...[
          Wrap(spacing: 6, children: [
            for (var i = 0; i < 7; i++)
              FilterChip(
                label: Text(dayLabels[i]),
                tooltip: const ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'][i],
                selected: _days.contains(i),
                onSelected: (v) => setState(() => v ? _days.add(i) : _days.remove(i)),
              ),
          ]),
          Padding(padding: const EdgeInsets.only(top: Spacing.xs), child: Text('None selected means every day.', style: muted)),
        ] else
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(_onceDate == null ? 'Pick a date' : '${_onceDate!.year}-${_onceDate!.month.toString().padLeft(2, '0')}-${_onceDate!.day.toString().padLeft(2, '0')}'),
            onTap: () async {
              final now = toServerLocal(DateTime.now(), widget.offsetMin);
              final d = await showDatePicker(
                context: context,
                initialDate: _onceDate ?? DateTime(now.year, now.month, now.day),
                firstDate: DateTime(now.year, now.month, now.day),
                lastDate: DateTime(now.year + 2),
              );
              if (d != null) setState(() => _onceDate = d);
            },
          ),
        const SizedBox(height: Spacing.md),
        Text('When it runs', style: theme.textTheme.titleSmall),
        const SizedBox(height: Spacing.xs),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'ask', label: Text('Ask')),
            ButtonSegment(value: 'plan', label: Text('Plan')),
            ButtonSegment(value: 'auto', label: Text('Auto')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xs),
          child: Text(
            switch (_mode) {
              'auto' => 'Auto: runs tools by itself with nobody watching. Only for tasks you trust.',
              'plan' => 'Plan: reads and thinks, then waits for you to approve a plan before changing anything.',
              _ => 'Ask: every tool call waits for your approval on your phone. Safest.',
            },
            style: muted?.copyWith(color: _mode == 'auto' ? theme.colorScheme.error : null),
          ),
        ),
      ]),
    );
  }
}
