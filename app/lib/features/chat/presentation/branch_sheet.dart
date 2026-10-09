import 'package:flutter/material.dart';

import '../../../core/spacing.dart';

/// "Branch from here" (proposal 42): copy the conversation up to a point into a NEW chat,
/// leaving this one untouched. Pops `'after'`, `'before'`, or nothing if dismissed.
Future<String?> showBranchSheet(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const BranchSheet(),
    );

class BranchSheet extends StatelessWidget {
  const BranchSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.xs),
            child: Text('Branch from here', style: theme.textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.call_split),
            title: const Text('Keep this message and its reply'),
            subtitle: const Text('Start a new chat from this point and take it in a different direction.'),
            onTap: () => Navigator.pop(context, 'after'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Branch before this message'),
            subtitle: const Text('Start a new chat with this message back in the box, ready to rewrite.'),
            onTap: () => Navigator.pop(context, 'before'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.xs, Spacing.lg, Spacing.md),
            child: Text(
              'This chat is left as it is. File changes made so far stay in the project and can\'t be rewound from the new chat.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
    );
  }
}
