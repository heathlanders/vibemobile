import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/domain/session.dart';
import '../data/project_api.dart';
import '../domain/scaffold.dart';
import 'scaffold_list_screen.dart';

/// Create a new project: name + a foundation scaffold + git toggle. Pops the
/// created [Project] on success (proposal 17). Name rules mirror the daemon's
/// allowlist so the user gets the error before the round-trip.
class NewProjectScreen extends StatefulWidget {
  const NewProjectScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<NewProjectScreen> createState() => _NewProjectScreenState();
}

// Same allowlist as the daemon (projects.ts NAME_RE): single path segment, no
// traversal, no leading dot, ≤64 chars.
final RegExp _nameRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

class _NewProjectScreenState extends State<NewProjectScreen> {
  late final ProjectApi _api = ProjectApi(dioFor(widget.creds));
  final _name = TextEditingController();

  List<ProjectScaffold> _scaffolds = [];
  String? _scaffoldId; // null = bare dir (no foundation files)
  bool _git = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadScaffolds(selectDefault: true);
  }

  Future<void> _loadScaffolds({bool selectDefault = false}) async {
    final list = await _api.listScaffolds();
    if (!mounted) return;
    setState(() {
      _scaffolds = list;
      // Default to the seeded foundations on first load; keep the user's pick on
      // a later refresh (drop it only if it was deleted meanwhile).
      if (selectDefault) {
        _scaffoldId = list.any((s) => s.id == 'seed-foundations')
            ? 'seed-foundations'
            : (list.isNotEmpty ? list.first.id : null);
      } else if (_scaffoldId != null && !list.any((s) => s.id == _scaffoldId)) {
        _scaffoldId = null;
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (!_nameRe.hasMatch(name)) {
      setState(() => _error = 'Letters, digits, . _ - only; no spaces or “/”; max 64.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final project = await _api.createProject(name: name, scaffoldId: _scaffoldId, git: _git);
      if (mounted) Navigator.of(context).pop(project);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _manageScaffolds() async {
    await Navigator.of(context).push(
      sharedAxisRoute(ScaffoldListScreen(creds: widget.creds)),
    );
    _loadScaffolds(); // pick up any new/edited/deleted templates
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New project'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating ? const Text('Creating…') : const Text('Create'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Project name',
              hintText: 'e.g. railroad-saas',
              helperText: 'Becomes a new directory in your projects root.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _scaffoldId,
                  decoration: const InputDecoration(labelText: 'Foundation', border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None (empty dir)')),
                    for (final s in _scaffolds) DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => setState(() => _scaffoldId = v),
                ),
              ),
              IconButton(
                tooltip: 'Manage foundations',
                icon: const Icon(Icons.tune),
                onPressed: _manageScaffolds,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Initialise git'),
            subtitle: const Text('git init + an initial commit of the scaffold'),
            value: _git,
            onChanged: (v) => setState(() => _git = v),
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
