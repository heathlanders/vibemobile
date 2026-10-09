import 'package:flutter/material.dart';

import '../../../core/spacing.dart';

/// What each level means in plain words (proposal 39). Order = the daemon's order.
const effortHints = <String, String>{
  'low': 'Fastest and cheapest. Quick questions and small edits.',
  'medium': 'Balanced.',
  'high': 'Careful. Good for most coding work.',
  'xhigh': 'Very thorough. Slower and costlier.',
  'max': 'Deepest reasoning. Slowest and costliest.',
};

/// Pick the session's reasoning effort. Pops the chosen level, `''` for "model default",
/// or nothing if dismissed. Models without effort support ignore the setting.
Future<String?> showEffortSheet(
  BuildContext context, {
  required String? current,
  required List<String> levels,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled:
      true, // six two-line options don't fit the default sheet height
  builder: (_) => EffortSheet(current: current, levels: levels),
);

class EffortSheet extends StatelessWidget {
  const EffortSheet({super.key, required this.current, required this.levels});
  final String? current;
  final List<String> levels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String value, String title, String hint) {
      final selected = (current ?? '') == value;
      return ListTile(
        selected: selected,
        title: Text(title),
        subtitle: Text(hint, style: theme.textTheme.bodySmall),
        trailing: selected ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, value),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                0,
                Spacing.lg,
                Spacing.xs,
              ),
              child: Text(
                'Reasoning effort',
                style: theme.textTheme.titleMedium,
              ),
            ),
            row('', 'Default', 'Whatever the model picks.'),
            for (final l in levels)
              row(l, l[0].toUpperCase() + l.substring(1), effortHints[l] ?? ''),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.xs,
                Spacing.lg,
                Spacing.md,
              ),
              child: Text(
                'Applies from the next message. Higher effort thinks longer, which costs more and takes longer.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
