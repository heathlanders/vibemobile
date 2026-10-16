import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../domain/context_usage.dart';

/// Slim strip above the composer: how full the model's context window is. Tap for the
/// breakdown and "Compact now" (proposal 40). Turns amber near the auto-compaction point.
class ContextStrip extends StatelessWidget {
  const ContextStrip({super.key, required this.usage, required this.onTap, this.onFresh});
  final ContextUsage usage;
  final VoidCallback onTap;

  /// "Write handoff & start fresh" — offered once the window is filling up (null = never).
  final VoidCallback? onFresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = usage.high ? scheme.tertiary : scheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 3),
        child: Row(children: [
          Icon(Icons.memory_outlined, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: Spacing.xs),
          Text('Context ${usage.label}', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: LinearProgressIndicator(
              value: usage.fractionOfCompactPoint ?? usage.fraction,
              minHeight: 3,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          if (onFresh != null && usage.nudgeFresh)
            InkWell(
              onTap: onFresh,
              child: Padding(
                padding: const EdgeInsets.only(left: Spacing.sm),
                child: Text('Fresh session ›', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.tertiary)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Breakdown of what fills the window, plus a manual compaction button. [onCompact] is
/// null while a turn is running (the daemon refuses then anyway).
Future<void> showContextSheet(BuildContext context,
        {required ContextUsage usage, required VoidCallback? onCompact, VoidCallback? onFresh}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ContextSheet(usage: usage, onCompact: onCompact, onFresh: onFresh),
    );

class ContextSheet extends StatelessWidget {
  const ContextSheet({super.key, required this.usage, required this.onCompact, this.onFresh});
  final ContextUsage usage;
  final VoidCallback? onCompact;
  final VoidCallback? onFresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Context window', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.xs),
          Text('${tokenLabel(usage.tokens)} of ${tokenLabel(usage.max)} tokens used (${usage.percent}%)', style: theme.textTheme.bodyMedium),
          const SizedBox(height: Spacing.sm),
          LinearProgressIndicator(value: usage.fraction, minHeight: 6),
          const SizedBox(height: Spacing.xs),
          Text(
            usage.autoCompactAt == null
                ? 'Automatic compaction is off.'
                : 'Older turns are summarized automatically at ${tokenLabel(usage.autoCompactAt!)}.',
            style: muted,
          ),
          const SizedBox(height: Spacing.md),
          for (final c in usage.categories.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(c.name, style: theme.textTheme.bodyMedium)),
                Text(tokenLabel(c.tokens), style: theme.textTheme.bodySmall),
              ]),
            ),
          const SizedBox(height: Spacing.md),
          Text('Instructions in force', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.xs),
          if (usage.memoryFiles.isEmpty)
            Text('No CLAUDE.md or memory file was loaded for this session.', style: muted)
          else
            for (final m in usage.memoryFiles)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.description_outlined, size: 14),
                  const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text('${m.fileName} · ${m.kind}', style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                  ),
                  Text(tokenLabel(m.tokens), style: theme.textTheme.bodySmall),
                ]),
              ),
          if (usage.rulesApplied != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                Icon(usage.rulesApplied! ? Icons.check_circle_outline : Icons.remove_circle_outline, size: 14),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    usage.rulesApplied!
                        ? (usage.ruleNames.isEmpty
                            ? 'Server storage rules: applied to this chat'
                            : 'Server rules applied: ${usage.ruleNames.join(', ')}')
                        : 'Server storage rules: not applied (off, or this chat started before they were enabled)',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ]),
            ),
          const SizedBox(height: Spacing.md),
          FilledButton.icon(
            icon: const Icon(Icons.compress),
            label: const Text('Compact now'),
            onPressed: onCompact == null
                ? null
                : () {
                    Navigator.pop(context);
                    onCompact!();
                  },
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            onCompact == null
                ? 'Wait for the current reply to finish, then compact.'
                : 'Summarizes the earlier conversation to free space. Your messages stay visible here; the model works from the summary.',
            style: muted,
          ),
          if (onFresh != null) ...[
            const SizedBox(height: Spacing.md),
            OutlinedButton.icon(
              icon: const Icon(Icons.fiber_new_outlined),
              label: const Text('Write handoff & start fresh'),
              onPressed: onCompact == null
                  ? null
                  : () {
                      Navigator.pop(context);
                      onFresh!();
                    },
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Preferred over compaction: this chat writes a Handoff file, then a new chat resumes from it with a clean context.',
              style: muted,
            ),
          ],
        ]),
      ),
    );
  }
}
