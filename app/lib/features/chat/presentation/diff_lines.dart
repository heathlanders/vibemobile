import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../../../core/theme.dart';

/// Monospace style for diff/file text (DESIGN.md §3).
TextStyle monoStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall!.copyWith(fontFamily: AppTheme.monoFontFamily);

/// One line of a unified diff, tinted by its prefix. Shared by the file-diff
/// screen (post-hoc view) and the permission card's pre-approval preview
/// (proposal 02) so both render an identical diff.
class DiffLine extends StatelessWidget {
  const DiffLine({super.key, required this.line});
  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color? bg;
    Color? fg;
    if (line.startsWith('+')) {
      bg = Colors.green.withValues(alpha: 0.12);
    } else if (line.startsWith('-')) {
      bg = theme.colorScheme.error.withValues(alpha: 0.12);
    } else if (line.startsWith('@@') || line.startsWith('…') || line.startsWith(r'\')) {
      // `\ No newline at end of file` is diff metadata, not content — dim it
      // like a hunk header instead of rendering it as a normal line.
      fg = theme.colorScheme.onSurfaceVariant;
    }
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Text(line, style: monoStyle(context).copyWith(color: fg)),
    );
  }
}
