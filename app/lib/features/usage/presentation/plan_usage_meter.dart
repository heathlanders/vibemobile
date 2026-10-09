import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../chat/domain/session_usage.dart';
import '../data/plan_usage_api.dart';
import '../domain/plan_usage.dart';

/// Always-on Max-plan meters (ADR 0020): the rolling 5-hour window and the
/// weekly limits, each with an even-burn tick so "am I using what I pay for"
/// reads at a glance. [dense] = the rail/strip form (5h + 7d all-models only);
/// otherwise every weekly limit with its pace hint. Renders nothing while the
/// daemon has no data — never a fake number.
class PlanUsageMeter extends StatefulWidget {
  const PlanUsageMeter({super.key, required this.creds, this.dense = true, this.onTap, this.api});
  final Creds creds;
  final bool dense;
  final VoidCallback? onTap;

  /// Test seam; defaults to the paired daemon.
  final PlanUsageApi? api;

  /// The daemon caches for 5 min; polling faster only re-reads its cache.
  static const pollEvery = Duration(minutes: 2);

  @override
  State<PlanUsageMeter> createState() => _PlanUsageMeterState();
}

class _PlanUsageMeterState extends State<PlanUsageMeter> {
  late final PlanUsageApi _api = widget.api ?? PlanUsageApi(dioFor(widget.creds));
  PlanUsage? _data;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(PlanUsageMeter.pollEvery, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await _api.fetch();
      if (mounted) setState(() => _data = d);
    } catch (_) {
      // Fail soft: keep showing the last value we had.
    }
  }

  @override
  Widget build(BuildContext context) {
    final usage = _data?.usage;
    if (usage == null) {
      return widget.dense
          ? const SizedBox.shrink()
          : Text(
              'Plan limits unavailable (not on a Max login, or the usage endpoint is rate-limiting).',
              style: Theme.of(context).textTheme.bodySmall,
            );
    }
    final now = DateTime.now();
    final rows = <Widget>[
      if (usage.session != null)
        _Meter(
          limit: usage.session!,
          title: widget.dense ? '5h' : 'Current 5-hour window',
          window: sessionWindow,
          now: now,
          dense: widget.dense,
        ),
      for (final w in widget.dense ? usage.weekly.take(1) : usage.weekly)
        _Meter(
          limit: w,
          title: widget.dense ? '7d' : 'Weekly · ${w.label}',
          window: weeklyWindow,
          now: now,
          dense: widget.dense,
        ),
    ];
    final at = _data?.fetchedAt;
    final stale = at != null && now.difference(at) > const Duration(minutes: 15);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...rows,
        if (stale && !widget.dense)
          Text('As of ${fmtAgo(now.difference(at))} ago', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    if (widget.onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: widget.onTap,
      child: Padding(padding: const EdgeInsets.all(Spacing.xs), child: body),
    );
  }
}

String fmtAgo(Duration d) => d.inHours >= 1 ? '${d.inHours}h' : '${d.inMinutes}m';

class _Meter extends StatelessWidget {
  const _Meter({
    required this.limit,
    required this.title,
    required this.window,
    required this.now,
    required this.dense,
  });
  final UsageLimit limit;
  final String title;
  final Duration window;
  final DateTime now;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final elapsed = windowElapsed(limit.resetsAt, window, now);
    final pace = paceOf(limit, window, now);
    final reset = fmtReset(limit.resetsAt, now);
    final color = switch (limit.severity) {
      'warning' => Colors.orange,
      'critical' || 'exceeded' => t.colorScheme.error,
      _ => t.colorScheme.primary,
    };
    final paceText = switch (pace) {
      Pace.under => 'Under pace — room to push',
      Pace.over => 'Over pace — may hit the limit early',
      Pace.onTrack => 'On pace',
      null => null,
    };
    final small = dense ? t.textTheme.labelSmall : t.textTheme.bodySmall;
    final muted = small?.copyWith(color: t.colorScheme.outline);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? Spacing.xs : Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(title, style: dense ? small : t.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
              ),
              Text('${limit.pct.round()}%', style: small),
            ],
          ),
          const SizedBox(height: 2),
          // Bar + even-burn tick: fill left of the tick = capacity unused so far.
          SizedBox(
            height: dense ? 6 : 8,
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(value: (limit.pct / 100).clamp(0, 1).toDouble(), color: color),
                    ),
                  ),
                  if (elapsed != null)
                    Positioned(
                      left: (c.maxWidth * elapsed - 1).clamp(0, c.maxWidth - 2).toDouble(),
                      top: -2,
                      bottom: -2,
                      child: Container(width: 2, color: t.colorScheme.onSurface),
                    ),
                ],
              ),
            ),
          ),
          if (reset != '') ...[const SizedBox(height: 2), Text(dense ? reset : 'Resets in $reset', style: muted)],
          if (!dense && paceText != null)
            Text(
              paceText,
              style: small?.copyWith(
                color: pace == Pace.under
                    ? t.colorScheme.primary
                    : (pace == Pace.over ? Colors.orange : t.colorScheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}
