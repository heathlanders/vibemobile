import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import '../data/prompt_api.dart';
import '../domain/prompt.dart';
import 'improve_prompt.dart';

/// Create or edit a prompt: title, body (with `{{vars}}`), tags, and scope
/// (global or a specific project). Pops `true` on save.
class PromptEditScreen extends StatefulWidget {
  const PromptEditScreen({super.key, required this.creds, this.existing, this.initialBody});
  final Creds creds;
  final Prompt? existing;

  /// Prefill for a new prompt (e.g. saved from past prompts).
  final String? initialBody;

  @override
  State<PromptEditScreen> createState() => _PromptEditScreenState();
}

class _PromptEditScreenState extends State<PromptEditScreen> {
  late final PromptApi _api = PromptApi(dioFor(widget.creds));
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _body = TextEditingController(text: widget.existing?.body ?? widget.initialBody ?? '');
  late final _tags = TextEditingController(text: widget.existing?.tags.join(', ') ?? '');

  List<Project> _projects = [];
  String? _projectId; // null = global
  bool _alwaysApply = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _projectId = widget.existing?.projectId;
    _alwaysApply = widget.existing?.alwaysApply ?? false;
    _body.addListener(() => setState(() {}));
    SessionApi(dioFor(widget.creds)).projects().then((p) {
      if (mounted) setState(() => _projects = p);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _error = 'Title and body are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final tags = _tags.text.trim();
      if (widget.existing != null) {
        await _api.update(widget.existing!.id, {'title': title, 'body': body, 'tags': tags, 'project_id': _projectId,
          'always_apply': _alwaysApply && extractVars(body).isEmpty});
      } else {
        await _api.create(
          title: title,
          body: body,
          tags: tags.isEmpty ? null : tags,
          projectId: _projectId,
          alwaysApply: _alwaysApply && extractVars(body).isEmpty,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasVars = extractVars(_body.text).isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New prompt' : 'Edit prompt'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving ? const Text('Saving…') : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _body,
            minLines: 4,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'Body',
              hintText: 'Use {{vars}} for fill-ins, e.g. Refactor {{file}} for {{goal}}',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
              label: const Text('Improve'),
              onPressed: () async {
                final better = await improvePromptFlow(context, _api, _body.text);
                if (better != null) _body.text = better;
              },
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(labelText: 'Tags (comma-separated)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String?>(
            initialValue: _projectId,
            decoration: const InputDecoration(labelText: 'Scope', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: null, child: Text('Global (all projects)')),
              for (final p in _projects) DropdownMenuItem(value: p.id, child: Text(p.label)),
            ],
            onChanged: (v) => setState(() => _projectId = v),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Apply to every session'),
            subtitle: Text(
              hasVars
                  ? 'Not available while the body has {{vars}}.'
                  : 'Appended to the system prompt of new chats ${_projectId == null ? 'in every project' : 'in this project'}. '
                      'Running chats keep what they started with.',
            ),
            value: _alwaysApply && !hasVars,
            onChanged: hasVars ? null : (v) => setState(() => _alwaysApply = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
