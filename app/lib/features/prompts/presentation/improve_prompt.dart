import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../data/prompt_api.dart';

/// "Improve prompt" (ADR 0018): ask the server to rewrite [text], then show the
/// original and the rewrite side by side (stacked on narrow screens). Returns
/// the rewrite if accepted, null if cancelled or it failed (error shown).
Future<String?> improvePromptFlow(BuildContext context, PromptApi api, String text) async {
  if (text.trim().isEmpty) return null;
  final future = api.improve(text);
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
