import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/prompt_api.dart';
import '../domain/prompt.dart';
import 'prompt_edit_screen.dart';
import 'prompt_history_screen.dart';
import 'prompt_use_screen.dart';

/// The prompt library: browse/search templates, create/edit/delete, and "Use" a
/// prompt (fill its vars → fire into a session).
class PromptListScreen extends StatefulWidget {
  const PromptListScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<PromptListScreen> createState() => _PromptListScreenState();
}

class _PromptListScreenState extends State<PromptListScreen> {
  late final PromptApi _api = PromptApi(dioFor(widget.creds));
  bool _mostUsed = false;
  late Future<List<Prompt>> _future = _api.list();
  String _query = '';

  void _reload() => setState(() => _future = _api.list(mostUsed: _mostUsed));

  bool _matches(Prompt p) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return p.title.toLowerCase().contains(q) || p.tags.any((t) => t.toLowerCase().contains(q));
  }

  Future<void> _edit([Prompt? existing]) async {
    final saved = await Navigator.of(context).push<bool>(
      sharedAxisRoute(PromptEditScreen(creds: widget.creds, existing: existing)),
    );
    if (saved == true) _reload();
  }

  Future<void> _delete(Prompt p) async {
    await _api.delete(p.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt library'),
        actions: [
          IconButton(
            tooltip: _mostUsed ? 'Sorted by most used' : 'Sorted by recently edited',
            icon: Icon(_mostUsed ? Icons.trending_up : Icons.schedule),
            onPressed: () {
              _mostUsed = !_mostUsed;
              _reload();
            },
          ),
          IconButton(
            tooltip: 'Past prompts',
            icon: const Icon(Icons.history),
            onPressed: () async {
              await Navigator.of(context).push(sharedAxisRoute(PromptHistoryScreen(creds: widget.creds)));
              _reload(); // may have saved one
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('New prompt'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search title or tag',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: FutureBuilder<List<Prompt>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SkeletonList();
                  }
                  if (snap.hasError) return ErrorBody(message: '${snap.error}');
                  final prompts = (snap.data ?? []).where(_matches).toList();
                  if (prompts.isEmpty) {
                    return const EmptyState(
                      icon: Icons.bookmarks_outlined,
                      title: 'No prompts',
                      hint: 'Tap “New prompt” to save a reusable template.',
                    );
                  }
                  return ListView.builder(
                    itemCount: prompts.length,
                    itemBuilder: (context, i) {
                      final p = prompts[i];
                      return ListTile(
                        leading: Icon(p.isGlobal ? Icons.public : Icons.folder_outlined),
                        title: Text(p.title),
                        subtitle: p.tags.isEmpty && p.useCount == 0 && !p.alwaysApply
                            ? null
                            : Text([if (p.alwaysApply) 'Always on', ...p.tags, if (p.useCount > 0) 'used ${p.useCount}×'].join(' · ')),
                        onTap: () => Navigator.of(context).push(
                          sharedAxisRoute(PromptUseScreen(creds: widget.creds, prompt: p)),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => v == 'edit' ? _edit(p) : _delete(p),
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
          ),
        ],
      ),
    );
  }
}
