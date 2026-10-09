import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../data/model_prefs.dart';
import '../data/session_api.dart';
import '../domain/session.dart';

/// Result of [chooseModel]: the picked id, or null for the server default.
typedef ModelChoice = ({String? id, String? label});

/// Pick a model for a new chat (ADR 0007/0016). With no real choice (only the
/// gateway's "default" entry) it returns the default without showing a sheet.
/// Returns null when cancelled or the list failed (the error is shown).
Future<ModelChoice?> chooseModel(BuildContext context, SessionApi api, {String title = 'Choose a model'}) async {
  final List<ModelInfo> models;
  try {
    models = await api.models();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return null;
  }
  if (models.length <= 1 && (models.isEmpty || models.first.id == 'default')) return (id: null, label: null);
  final last = await ModelPrefs.last();
  if (!context.mounted) return null;
  final picked = await showModalBottomSheet<ModelInfo>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ModelSheet(models: models, lastId: last, title: title),
  );
  if (picked == null) return null;
  await ModelPrefs.setLast(picked.id);
  return (id: picked.id, label: picked.label);
}

/// Model ids matching [query] (label, id, provider, tags; case-insensitive).
/// Pure → unit-tested.
List<ModelInfo> filterModels(List<ModelInfo> models, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return models;
  return models
      .where((m) => [m.label, m.id, m.provider ?? '', ...m.tags].any((s) => s.toLowerCase().contains(q)))
      .toList();
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.models, required this.lastId, required this.title});
  final List<ModelInfo> models;
  final String? lastId;
  final String title;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hits = filterModels(widget.models, _query);
    // Group by provider, keeping the server's order within and across groups.
    final groups = <String, List<ModelInfo>>{};
    for (final m in hits) {
      (groups[m.provider ?? 'other'] ??= []).add(m);
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, 0),
            child: Row(children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('${hits.length}', style: Theme.of(context).textTheme.labelSmall),
            ]),
          ),
          if (widget.models.length > 8)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.sm),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Filter by name, provider or tag',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          Expanded(
            child: ListView(controller: scroll, children: [
              for (final MapEntry(key: provider, value: models) in groups.entries) ...[
                if (groups.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, Spacing.xs),
                    child: Text(provider.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
                  ),
                for (final m in models)
                  ListTile(
                    dense: true,
                    leading: Icon(m.id == widget.lastId ? Icons.check_circle : Icons.smart_toy_outlined),
                    title: Text(m.label),
                    subtitle: m.detail.isEmpty ? null : Text(m.detail),
                    selected: m.id == widget.lastId,
                    onTap: () => Navigator.pop(context, m),
                  ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
