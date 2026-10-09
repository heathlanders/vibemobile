import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../data/project_api.dart';
import '../domain/scaffold.dart';

/// Create or edit a foundation scaffold: name, description, and its files
/// (path + body, with `{{project_name}}`/`{{date}}` tokens). Pops `true` on save.
class ScaffoldEditScreen extends StatefulWidget {
  const ScaffoldEditScreen({super.key, required this.creds, this.existing});
  final Creds creds;
  final ProjectScaffold? existing;

  @override
  State<ScaffoldEditScreen> createState() => _ScaffoldEditScreenState();
}

/// Mutable editor row backing one ScaffoldFile.
class _FileRow {
  _FileRow(ScaffoldFile? f)
      : path = TextEditingController(text: f?.path ?? ''),
        body = TextEditingController(text: f?.body ?? '');
  final TextEditingController path;
  final TextEditingController body;

  void dispose() {
    path.dispose();
    body.dispose();
  }
}

class _ScaffoldEditScreenState extends State<ScaffoldEditScreen> {
  late final ProjectApi _api = ProjectApi(dioFor(widget.creds));
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  late final List<_FileRow> _rows =
      (widget.existing?.files ?? const <ScaffoldFile>[]).map((f) => _FileRow(f)).toList();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addFile() => setState(() => _rows.add(_FileRow(null)));

  void _removeFile(int i) => setState(() => _rows.removeAt(i).dispose());

  Future<void> _save() async {
    final name = _name.text.trim();
    final files = [
      for (final r in _rows)
        if (r.path.text.trim().isNotEmpty) ScaffoldFile(path: r.path.text.trim(), body: r.body.text),
    ];
    if (name.isEmpty || files.isEmpty) {
      setState(() => _error = 'Name and at least one file (with a path) are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final desc = _description.text.trim().isEmpty ? null : _description.text.trim();
      if (widget.existing != null) {
        await _api.updateScaffold(widget.existing!.id, {
          'name': name,
          'description': desc,
          'files': files.map((f) => f.toJson()).toList(),
        });
      } else {
        await _api.createScaffold(name: name, description: desc, files: files);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New foundation' : 'Edit foundation'),
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
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Files', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('${_rows.length}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _rows.length; i++) _fileCard(i),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addFile,
            icon: const Icon(Icons.add),
            label: const Text('Add file'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _fileCard(int i) {
    final row = _rows[i];
    return Card(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: row.path,
                    decoration: const InputDecoration(
                      labelText: 'Path',
                      hintText: 'e.g. CLAUDE.md or docs/README.md',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove file',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeFile(i),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: row.body,
              minLines: 3,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Body',
                hintText: 'Supports {{project_name}} and {{date}}',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
