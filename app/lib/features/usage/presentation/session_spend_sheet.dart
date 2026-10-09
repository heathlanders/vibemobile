import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/spend_api.dart';
import '../domain/spend.dart';
import 'usage_screen.dart' show tokens, usd;

/// One session's token detail (ADR 0017 "Next"), opened from the chat header:
/// all-time ledger totals plus a row per model (a Haiku subagent shows apart).
Future<void> showSessionSpendSheet(BuildContext context, Creds creds, String sessionId, {SpendApi? api}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SessionSpendSheet(future: (api ?? SpendApi(dioFor(creds))).session(sessionId)),
  );
}

class SessionSpendSheet extends StatelessWidget {
  const SessionSpendSheet({super.key, required this.future});
  final Future<SpendReport> future;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: FutureBuilder<SpendReport>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorBody(message: '${snap.error}');
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(Spacing.xl), child: LinearProgressIndicator());
          final r = snap.data!;
          final t = r.totals;
          if (t.turns == 0) {
            return const Padding(
              padding: EdgeInsets.all(Spacing.xl),
              child: Text('No completed turns recorded for this session yet.'),
            );
          }
          final hit = t.cacheHitRate;
          Widget line(String label, String value) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
                  Text(value, style: theme.textTheme.bodyMedium),
                ]),
              );
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Session tokens', style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.sm),
                line('Turns', '${t.turns}'),
                line('Input, uncached', tokens(t.input)),
                line('Cache reads', tokens(t.cacheRead)),
                line('Cache writes', tokens(t.cacheWrite)),
                line('Output', tokens(t.output)),
                line('Cache hit', hit == null ? '—' : '${(hit * 100).round()}%'),
                line('Avg context / turn', tokens(t.context ~/ t.turns)),
                line('Cost (API-equivalent on Max)', usd(t.cost)),
                if (r.rows.length > 1) ...[
                  const SizedBox(height: Spacing.md),
                  Text('By model', style: theme.textTheme.titleSmall),
                  const SizedBox(height: Spacing.xs),
                  for (final m in r.rows)
                    line(m.name, '${m.totals.turns} turns · ${tokens(m.totals.context)} in · ${usd(m.totals.cost)}'),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
