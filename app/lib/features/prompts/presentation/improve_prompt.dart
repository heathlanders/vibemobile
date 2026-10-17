import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../../chat/domain/chat_message.dart';
import '../data/prompt_api.dart';

/// "Improve prompt" (ADR 0018): the user picks Improve or Go deeper (proposal 61), the
/// server rewrites [text], then the original and the rewrite show side by side
/// (stacked on narrow screens). Returns the rewrite if accepted, null if
/// cancelled or it failed (error shown).
Future<String?> improvePromptFlow(BuildContext context, PromptApi api, String text) async {
  if (text.trim().isEmpty) return null;
  final mode = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Improve prompt'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, 'improve'),
          child: const ListTile(
            leading: Icon(Icons.auto_fix_high_outlined),
            title: Text('Improve'),
            subtitle: Text('Clearer goal, checkable success, explicit scope'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, 'deeper'),
          child: const ListTile(
            leading: Icon(Icons.layers_outlined),
            title: Text('Go deeper'),
            subtitle: Text('Pro-grade methods, raw sources and external evidence, without adding scope'),
          ),
        ),
      ],
    ),
  );
  if (mode == null || !context.mounted) return null;
  return _improveWith(context, api, text, mode);
}

/// Chat's Improve (proposal 63): a sheet with a text box (prefilled with [draft]) and the chat's
/// recent user/assistant [messages] to start from, then Improve or Go deeper. Returns the
/// rewrite if accepted, null otherwise.
Future<String?> improveFromChat(BuildContext context, PromptApi api, {required String draft, required List<ChatMessage> messages}) async {
  final picked = await showModalBottomSheet<(String, String)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ImproveSourceSheet(draft: draft, messages: messages),
  );
  if (picked == null || !context.mounted) return null;
  return _improveWith(context, api, picked.$1, picked.$2);
}

Future<String?> _improveWith(BuildContext context, PromptApi api, String text, String mode) {
  final future = api.improve(text, mode: mode);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Improve prompt'),
      content: SizedBox(
        width: 760,
        child: FutureBuilder<String>(
          future: future,
          builder: (ctx, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) {
              return const SizedBox(
                height: 120,
                child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: Spacing.md),
                  Text('Rewriting…'),
                ])),
              );
            }
            final panes = [_Pane(label: 'Original', text: text), _Pane(label: 'Improved', text: snap.data!)];
            return LayoutBuilder(
              builder: (ctx, box) => box.maxWidth >= 600
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: panes[0]),
                      const SizedBox(width: Spacing.md),
                      Expanded(child: panes[1]),
                    ])
                  : Column(mainAxisSize: MainAxisSize.min, children: [panes[0], const SizedBox(height: Spacing.md), panes[1]]),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep original')),
        FutureBuilder<String>(
          future: future,
          builder: (ctx, snap) => FilledButton(
            onPressed: snap.hasData ? () => Navigator.pop(ctx, snap.data) : null,
            child: const Text('Use improved'),
          ),
        ),
      ],
    ),
  );
}

class _Pane extends StatelessWidget {
  const _Pane({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: theme.textTheme.labelMedium),
      const SizedBox(height: Spacing.xs),
      Container(
        constraints: const BoxConstraints(maxHeight: 360),
        width: double.infinity,
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: SingleChildScrollView(child: SelectableText(text, style: theme.textTheme.bodySmall)),
      ),
    ]);
  }
}

/// The source picker behind [improveFromChat]. Pops `(text, mode)` with mode `improve` or `deeper`.
class ImproveSourceSheet extends StatefulWidget {
  const ImproveSourceSheet({super.key, required this.draft, required this.messages});
  final String draft;
  final List<ChatMessage> messages;

  @override
  State<ImproveSourceSheet> createState() => _ImproveSourceSheetState();
}

class _ImproveSourceSheetState extends State<ImproveSourceSheet> {
  late final _text = TextEditingController(text: widget.draft);

  // Newest first: what you sent and what Claude answered, nothing else.
  late final _sources = [
    for (final m in widget.messages.reversed)
      if ((m.role == ChatRole.user || m.role == ChatRole.assistant) && !m.superseded && m.text.trim().isNotEmpty) m,
  ].take(30).toList();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _text.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Improve prompt', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _text,
              autofocus: widget.draft.trim().isEmpty,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Type a prompt, or pick a message below',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton.icon(
                onPressed: ready ? () => Navigator.pop(context, (_text.text, 'deeper')) : null,
                icon: const Icon(Icons.layers_outlined, size: 18),
                label: const Text('Go deeper'),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton.icon(
                onPressed: ready ? () => Navigator.pop(context, (_text.text, 'improve')) : null,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                label: const Text('Improve'),
              ),
            ]),
            if (_sources.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Text('Or start from a message', style: theme.textTheme.labelMedium),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final m in _sources)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(m.role == ChatRole.user ? Icons.person_outline : Icons.smart_toy_outlined, size: 20),
                      title: Text(m.role == ChatRole.user ? 'You' : 'Claude', style: theme.textTheme.labelSmall),
                      subtitle: Text(m.text.trim(), maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => setState(() {
                        _text.text = m.text.trim();
                        _text.selection = TextSelection.collapsed(offset: _text.text.length);
                      }),
                    ),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
