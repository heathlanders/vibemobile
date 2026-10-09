import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/spend_api.dart';
import '../domain/spend.dart';
import 'plan_usage_meter.dart';

/// Token & cost dashboard (ADR 0017): headline tiles, spend per day, a ranked
/// breakdown by model / project / provider, and rule-based saving tips.
/// Single-series marks throughout (one hue, values in text ink).
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.creds, this.api});
  final Creds creds;

  /// Test seam; defaults to the paired daemon.
  final SpendApi? api;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  late final SpendApi _api = widget.api ?? SpendApi(dioFor(widget.creds));
  int _days = 30;
  String _group = 'model';
  late Future<(SpendReport, SpendReport, SpendReport, SpendReport)> _future = _load();

  // by-model (tiles + tips), by-day (chart), by-project (CLAUDE.md tip), and the
  // chosen breakdown.
  Future<(SpendReport, SpendReport, SpendReport, SpendReport)> _load() async {
    final r = await Future.wait([
      _api.report(group: 'model', days: _days),
      _api.report(group: 'day', days: _days),
      _api.report(group: 'project', days: _days),
      if (_group == 'provider') _api.report(group: _group, days: _days),
    ]);
    final breakdown = switch (_group) { 'model' => r[0], 'project' => r[2], _ => r[3] };
    return (r[0], r[1], r[2], breakdown);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage'),
        actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload)],
      ),
      body: FutureBuilder<(SpendReport, SpendReport, SpendReport, SpendReport)>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorBody(message: '${snap.error}');
          if (!snap.hasData) return const SkeletonList(rows: 5);
          final (byModel, byDay, byProject, breakdown) = snap.data!;
          final tips = savingsTips(byModel, byProject: byProject);
          return ListView(
            padding: const EdgeInsets.all(Spacing.lg),
            children: [
              // Max-plan windows first (ADR 0020): the real constraint on a
              // subscription; the $ figures below are API-equivalent only.
              Text('Plan limits', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Spacing.xs),
              PlanUsageMeter(creds: widget.creds, dense: false),
              const SizedBox(height: Spacing.xl),
              // Filters: one row above everything they drive.
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  for (final d in const [7, 30, 90])
                    ChoiceChip(
                      label: Text('$d days'),
                      selected: _days == d,
                      onSelected: (_) {
                        _days = d;
                        _reload();
                      },
                    ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              _Tiles(totals: byModel.totals),
              const SizedBox(height: Spacing.xl),
              Text('Spend per day', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Spacing.sm),
              _DailyBars(rows: byDay.rows),
              const SizedBox(height: Spacing.xl),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Spacing.md,
                runSpacing: Spacing.sm,
                children: [
                  Text('Breakdown', style: Theme.of(context).textTheme.titleSmall),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'model', label: Text('Model')),
                      ButtonSegment(value: 'project', label: Text('Project')),
                      ButtonSegment(value: 'provider', label: Text('Provider')),
                    ],
                    selected: {_group},
                    onSelectionChanged: (s) {
                      _group = s.first;
                      _reload();
                    },
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              _RankedBars(rows: breakdown.rows),
              if (tips.isNotEmpty) ...[
                const SizedBox(height: Spacing.xl),
                Text('Saving tokens', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                for (final t in tips)
                  Card(
                    child: ListTile(leading: const Icon(Icons.lightbulb_outline), title: Text(t)),
                  ),
              ],
              const SizedBox(height: Spacing.lg),
              Text(
                'Claude cost on a Max plan is the API-equivalent figure, not a charge.',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}

String usd(double v) => v >= 100 ? '\$${v.toStringAsFixed(0)}' : '\$${v.toStringAsFixed(v < 1 ? 3 : 2)}';

String tokens(int t) => t >= 1000000
    ? '${(t / 1000000).toStringAsFixed(1)}M'
    : t >= 1000
    ? '${(t / 1000).toStringAsFixed(t >= 10000 ? 0 : 1)}k'
    : '$t';

class _Tiles extends StatelessWidget {
  const _Tiles({required this.totals});
  final SpendTotals totals;

  @override
  Widget build(BuildContext context) {
    final hit = totals.cacheHitRate;
    final tiles = [
      ('Cost', usd(totals.cost)),
      ('Turns', '${totals.turns}'),
      ('Tokens in / out', '${tokens(totals.context)} / ${tokens(totals.output)}'),
      ('Cache hit', hit == null ? '—' : '${(hit * 100).round()}%'),
    ];
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        // Four across when there's room, otherwise two.
        final across = box.maxWidth >= 4 * 160 + 3 * Spacing.md ? 4 : 2;
        final width = (box.maxWidth - (across - 1) * Spacing.md) / across;
        return Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.md,
          children: [
            for (final (label, value) in tiles)
              SizedBox(
                width: width.clamp(0, 220).toDouble(),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: Spacing.xs),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(value, style: theme.textTheme.headlineSmall, maxLines: 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Vertical bars, one per day with spend; baseline-anchored, 4px rounded tops,
/// 2px gaps, tooltip per bar. Days with no rows simply aren't drawn.
class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.rows});
  final List<SpendRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rows.isEmpty) {
      return SizedBox(
        height: 60,
        child: Center(child: Text('No turns recorded yet', style: theme.textTheme.bodySmall)),
      );
    }
    final max = rows.map((r) => r.totals.cost).fold<double>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 156,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Text('max ${usd(max)}/day', style: theme.textTheme.labelSmall),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final r in rows)
                  Expanded(
                    child: Tooltip(
                      message: '${r.key}\n${usd(r.totals.cost)} · ${r.totals.turns} turns',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1), // 2px gap between bars
                        child: FractionallySizedBox(
                          heightFactor: max == 0 ? 0.02 : (r.totals.cost / max).clamp(0.02, 1.0),
                          alignment: Alignment.bottomCenter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: Spacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(rows.first.key, style: theme.textTheme.labelSmall),
              if (rows.length > 1) Text(rows.last.key, style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// Ranked horizontal bars: name, bar scaled to the top row, cost + turns in text
/// ink. Doubles as the table view.
class _RankedBars extends StatelessWidget {
  const _RankedBars({required this.rows});
  final List<SpendRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (rows.isEmpty) return Text('Nothing in this range', style: theme.textTheme.bodySmall);
    final max = rows.first.totals.cost;
    return Column(
      children: [
        for (final r in rows)
          Tooltip(
            message:
                '${tokens(r.totals.context)} in · ${tokens(r.totals.output)} out'
                '${r.totals.cacheHitRate == null ? '' : ' · ${(r.totals.cacheHitRate! * 100).round()}% cached'}',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(r.name, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: max == 0 ? 0.01 : (r.totals.cost / max).clamp(0.01, 1.0),
                        child: Container(
                          height: 10,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  SizedBox(
                    width: 110,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${usd(r.totals.cost)} · ${r.totals.turns} turns',
                        maxLines: 1,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
