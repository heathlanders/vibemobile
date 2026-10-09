import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/prompt_api.dart';
import '../../sessions/domain/session.dart' show relativeAge;
import '../domain/prompt.dart';
import 'prompt_edit_screen.dart';

/// Everything you've typed into any session (ADR 0018), newest first and
/// deduplicated — find a prompt that worked and save it to the library.
class PromptHistoryScreen extends StatefulWidget {
  const PromptHistoryScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<PromptHistoryScreen> createState() => _PromptHistoryScreenState();
}

class _PromptHistoryScreenState extends State<PromptHistoryScreen> {
  late final PromptApi _api = PromptApi(dioFor(widget.creds));
  late Future<List<PromptHistoryItem>> _future = _api.history();
  Timer? _debounce;

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _future = _api.history(q: q)));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _actions(PromptHistoryItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.bookmark_add_outlined),
            title: const Text('Save to library'),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, 'copy')),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: item.text));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
    } else if (action == 'save') {
      await Navigator.of(context).push(sharedAxisRoute(PromptEditScreen(creds: widget.creds, initialBody: item.text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search past prompts', border: InputBorder.none),
          onChanged: _search,
        ),
      ),
      body: FutureBuilder<List<PromptHistoryItem>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorBody(message: '${snap.error}');
          if (!snap.hasData) return const SkeletonList();
          final items = snap.data!;
          if (items.isEmpty) return const EmptyState(icon: Icons.history, title: 'No matching prompts');
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = items[i];
              return ListTile(
                title: Text(it.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  ?it.project,
                  if (it.times > 1) 'sent ${it.times}×',
                  if (it.lastTs != null) relativeAge(DateTime.tryParse(it.lastTs!)),
                ].where((s) => s.isNotEmpty).join(' · ')),
                onTap: () => _actions(it),
              );
            },
          );
        },
      ),
    );
  }
}
