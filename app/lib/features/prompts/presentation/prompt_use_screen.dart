import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/data/task_model_prefs.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/task_profile.dart';
import '../../sessions/presentation/model_picker.dart';
import '../data/prompt_api.dart';
import '../domain/prompt.dart';

/// Use a prompt: fill its `{{vars}}`, choose a target (an existing live Claude
/// session or a new one in a project), then open the chat with the filled text
/// sent as the first turn.
class PromptUseScreen extends StatefulWidget {
  const PromptUseScreen({super.key, required this.creds, required this.prompt, this.initialTarget});
  final Creds creds;
  final Prompt prompt;

  /// Preselected target, e.g. `new:<projectId>` when started from a project's
  /// "Start from template" (proposal 04).
  final String? initialTarget;

  @override
  State<PromptUseScreen> createState() => _PromptUseScreenState();
}

class _PromptUseScreenState extends State<PromptUseScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final List<String> _vars = extractVars(widget.prompt.body);
  late final Map<String, TextEditingController> _fields = {
    for (final v in _vars) v: TextEditingController(text: widget.prompt.varDefaults[v] ?? ''),
  };

  List<Project> _projects = [];
  List<Session> _liveClaude = [];
  late String? _target = widget.initialTarget; // 'session:<id>' | 'new:<projectId>'
  bool _loading = true;
  bool _sending = false;

  // Model per task (ADR 0016 follow-up): the filled prompt suggests a task kind,
  // whose profile model a NEW session starts on unless the user picks another.
  final _profiles = <TaskKind, ({String id, String label})?>{};
  ({String id, String label})? _override;

  String get _filled => fillTemplate(widget.prompt.body, {for (final e in _fields.entries) e.key: e.value.text});
  TaskKind? get _task => suggestTask(_filled);
  ({String id, String label})? get _model => _override ?? (_task == null ? null : _profiles[_task!]);

  Future<void> _changeModel() async {
    final c = await chooseModel(context, _api);
    if (c == null || !mounted) return;
    final id = c.id;
    setState(() => _override = id == null ? null : (id: id, label: c.label ?? id));
  }

  @override
  void initState() {
    super.initState();
    for (final f in _fields.values) {
      f.addListener(() => setState(() {})); // the suggestion follows the filled text
    }
    _load();
  }

  Future<void> _load() async {
    final projects = await _api.projects();
    final sessions = await _api.allSessions();
    for (final k in TaskKind.values) {
      _profiles[k] = await TaskModelPrefs.get(k);
    }
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _liveClaude = sessions.where((s) => s.kind == 'claude' && s.isLive).toList();
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _projectName(String id) => _projects.firstWhere(
        (p) => p.id == id,
        orElse: () => Project(id: id, path: id),
      ).label;

  Future<void> _send() async {
    unawaited(PromptApi(dioFor(widget.creds)).markUsed(widget.prompt.id).catchError((_) {})); // count the use; never blocks sending
    if (_target == null) return;
    final filled = _filled;
    setState(() => _sending = true);
    try {
      final Session session;
      // New session: prime the first turn server-side (proposal 15) — atomic,
      // no post-connect race. Existing live session: it's already running, so
      // send the filled prompt as a normal turn via initialMessage.
      String? initialMessage;
      if (_target!.startsWith('new:')) {
        session = await _api.create(_target!.substring(4), kind: 'claude', initialPrompt: filled, model: _model?.id);
      } else {
        session = _liveClaude.firstWhere((s) => s.id == _target!.substring(8));
        initialMessage = filled;
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        sharedAxisRoute(ChatScreen(creds: widget.creds, session: session, initialMessage: initialMessage)),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.prompt.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Spacing.lg),
              children: [
                if (_vars.isNotEmpty) ...[
                  Text('Variables', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final v in _vars)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.md),
                      child: TextField(
                        controller: _fields[v],
                        decoration: InputDecoration(labelText: v, border: const OutlineInputBorder()),
                      ),
                    ),
                  const Divider(height: 24),
                ],
                Text('Send to', style: Theme.of(context).textTheme.titleSmall),
                for (final s in _liveClaude)
                  _TargetTile(
                    selected: _target == 'session:${s.id}',
                    icon: Icons.smart_toy_outlined,
                    title: s.label,
                    subtitle: '${_projectName(s.projectId)} · live',
                    onTap: () => setState(() => _target = 'session:${s.id}'),
                  ),
                for (final p in _projects)
                  _TargetTile(
                    selected: _target == 'new:${p.id}',
                    icon: Icons.add,
                    title: 'New Claude session',
                    subtitle: p.label,
                    onTap: () => setState(() => _target = 'new:${p.id}'),
                  ),
                if (_target?.startsWith('new:') ?? false)
                  ListTile(
                    leading: const Icon(Icons.memory),
                    title: Text('Model: ${_model?.label ?? 'server default'}'),
                    subtitle: _override == null && _task != null
                        ? Text(_model == null
                            ? 'Reads as ${_task!.label} (no model set for it in Settings)'
                            : 'Suggested for ${_task!.label}')
                        : null,
                    trailing: TextButton(onPressed: _changeModel, child: const Text('Change')),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: (_target == null || _sending) ? null : _send,
                  icon: const Icon(Icons.send),
                  label: Text(_sending ? 'Sending…' : 'Send'),
                ),
              ],
            ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: selected ? const Icon(Icons.check_circle) : null,
      onTap: onTap,
    );
  }
}
