import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/project_api.dart';
import '../domain/scaffold.dart';
import 'scaffold_edit_screen.dart';

/// The foundation library: browse/create/edit/delete the scaffolds applied to
/// new projects (proposal 17). The multi-file analogue of the prompt library.
class ScaffoldListScreen extends StatefulWidget {
  const ScaffoldListScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<ScaffoldListScreen> createState() => _ScaffoldListScreenState();
}

class _ScaffoldListScreenState extends State<ScaffoldListScreen> {
  late final ProjectApi _api = ProjectApi(dioFor(widget.creds));
  late Future<List<ProjectScaffold>> _future = _api.listScaffolds();

  void _reload() => setState(() => _future = _api.listScaffolds());

  Future<void> _edit([ProjectScaffold? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      sharedAxisRoute(ScaffoldEditScreen(creds: widget.creds, existing: existing)),
    );
    if (saved == true) _reload();
  }

  Future<void> _delete(ProjectScaffold s) async {
    await _api.deleteScaffold(s.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Foundations')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New foundation'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<ProjectScaffold>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SkeletonList();
            }
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            final scaffolds = snap.data ?? [];
            if (scaffolds.isEmpty) {
              return const EmptyState(
                icon: Icons.foundation_outlined,
                title: 'No foundations',
                hint: 'Tap “New foundation” to define a starter file set.',
              );
            }
            return ListView.builder(
              itemCount: scaffolds.length,
              itemBuilder: (context, i) {
                final s = scaffolds[i];
                return ListTile(
                  leading: const Icon(Icons.foundation_outlined),
                  title: Text(s.name),
                  subtitle: Text(s.description ?? '${s.files.length} files'),
                  onTap: () => _edit(s),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'edit' ? _edit(s) : _delete(s),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
