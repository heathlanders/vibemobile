import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/system_api.dart';
import '../domain/system_snapshot.dart';

/// Server health (ADR 0019): read-only CPU, memory, disks, network, GPU, services and the
/// heaviest processes, refreshed every few seconds while open. Over-threshold
/// meters switch to the error colour AND carry a warning icon + label.
class SystemScreen extends StatefulWidget {
  const SystemScreen({super.key, required this.creds, this.api});
  final Creds creds;

  /// Test seam; defaults to the paired daemon.
  final SystemApi? api;

  static const refresh = Duration(seconds: 3);

  @override
  State<SystemScreen> createState() => _SystemScreenState();
}

class _SystemScreenState extends State<SystemScreen> {
  late final SystemApi _api = widget.api ?? SystemApi(dioFor(widget.creds));
  SystemSnapshot? _snap;
  DateTime? _snapAt;
  List<({String iface, double? rx, double? tx})> _rates = const [];
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(SystemScreen.refresh, (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final s = await _api.snapshot();
      final now = DateTime.now();
      if (mounted) {
        setState(() {
          final secs = _snapAt == null ? 0.0 : now.difference(_snapAt!).inMilliseconds / 1000;
          _rates = netRates(_snap, s, secs);
          _snap = s;
          _snapAt = now;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    return Scaffold(
      appBar: AppBar(title: Text(s == null || s.hostname.isEmpty ? 'System' : 'System · ${s.hostname}')),
      body: s == null
          ? (_error != null ? ErrorBody(message: '$_error') : const SkeletonList(rows: 5))
          : ListView(padding: const EdgeInsets.all(Spacing.lg), children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Spacing.md),
                  child: Text('Showing the last good reading — refresh failed.', style: Theme.of(context).textTheme.labelSmall),
                ),
              for (final a in s.alerts) _AlertBanner(message: a),
              if (s.alerts.isNotEmpty) const SizedBox(height: Spacing.md),
              _Section('Compute', [
                _Meter(
                  label: 'CPU',
                  frac: s.cpuPct / 100,
                  value: '${s.cpuPct.toStringAsFixed(0)}% of ${s.cores} cores',
                ),
                _Meter(
                  label: 'Memory',
                  frac: s.memUsedFrac,
                  value: '${bytesLabel(s.memTotal - s.memAvailable)} / ${bytesLabel(s.memTotal)}',
                  over: s.memUsedFrac > 0.9,
                ),
                if (s.swapTotal > 0)
                  _Meter(
                    label: 'Swap',
                    frac: s.swapUsedFrac,
                    value: '${bytesLabel(s.swapTotal - s.swapFree)} / ${bytesLabel(s.swapTotal)}',
                    over: s.swapUsedFrac > 0.5,
                  ),
                if (s.cpuTempC != null) _KeyValue('CPU temperature', '${s.cpuTempC} °C'),
                _KeyValue('Load (1 / 5 / 15 min)', s.load.map((l) => l.toStringAsFixed(2)).join(' / ')),
                _KeyValue('Uptime', uptimeLabel(s.uptimeSec)),
              ]),
              _Section('Disks', [
                for (final d in s.disks)
                  _Meter(
                    label: d.path,
                    frac: d.usedFrac,
                    value: '${bytesLabel(d.free)} free of ${bytesLabel(d.total)}',
                    over: d.usedFrac > s.diskAlertPercent / 100,
                  ),
              ]),
              if (s.footprint.isNotEmpty)
                _Section('Daemon data', [
                  for (final f in s.footprint) _KeyValue(f.label, '${f.truncated ? '≥ ' : ''}${bytesLabel(f.bytes)}'),
                  _KeyValue(
                    'Total',
                    '${bytesLabel(s.footprint.fold<int>(0, (a, f) => a + f.bytes))}'
                    '${s.dataAlertGb > 0 ? ' · alerts at ${s.dataAlertGb} GB' : ''}',
                  ),
                ]),
              if (_rates.isNotEmpty)
                _Section('Network', [
                  for (final r in _rates)
                    _KeyValue(
                      r.iface,
                      r.rx == null || r.tx == null ? 'measuring…' : '↓ ${rateLabel(r.rx!)} · ↑ ${rateLabel(r.tx!)}',
                    ),
                ]),
              if (s.gpus.isNotEmpty)
                _Section('GPU', [
                  for (final g in s.gpus) ...[
                    _Meter(label: g.name, frac: g.utilPct / 100, value: '${g.utilPct}% · ${g.tempC} °C', over: g.tempC >= 85),
                    _Meter(
                      label: 'VRAM',
                      frac: g.memTotalMb == 0 ? 0 : g.memUsedMb / g.memTotalMb,
                      value: '${g.memUsedMb} / ${g.memTotalMb} MB',
                    ),
                  ],
                ]),
              if (s.diagnostics case final d?)
                _Section('Diagnostics', [
                  _KeyValue(
                    'Tailscale',
                    d.tailscaleAvailable ? [d.tailscaleState ?? '?', ?d.dnsName].join(' · ') : 'unavailable',
                  ),
                  if (d.tailscaleAvailable) _KeyValue('tailscale serve', d.serving ? 'forwarding' : 'not forwarding'),
                  _KeyValue('Node (daemon / terminal)', '${d.daemonNode} / ${d.shellNode ?? '?'}'),
                  if (d.sdkVersion != null) _KeyValue('Agent SDK', d.sdkVersion!),
                  _KeyValue('Daemon uptime', uptimeLabel(d.daemonUptimeSec)),
                  _KeyValue('Push (FCM)', d.fcm ? 'configured' : 'off'),
                  for (final h in diagnosticHints(d))
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.sm),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: Spacing.sm),
                        Expanded(child: Text(h, style: Theme.of(context).textTheme.bodySmall)),
                      ]),
                    ),
                ]),
              _Section('Services', [
                Wrap(spacing: Spacing.sm, runSpacing: Spacing.sm, children: [
                  for (final sv in s.services)
                    Chip(
                      avatar: Icon(
                        sv.active ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: sv.active ? null : Theme.of(context).colorScheme.error,
                      ),
                      label: Text('${sv.name} · ${sv.state}'),
                    ),
                ]),
              ]),
              _Section('Top processes (memory)', [
                for (final p in s.top)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                      SizedBox(width: 72, child: Text('${p.cpuPct.toStringAsFixed(1)}%', textAlign: TextAlign.right)),
                      SizedBox(width: 88, child: Text(bytesLabel(p.rssKb * 1024), textAlign: TextAlign.right)),
                    ]),
                  ),
              ]),
              Text(
                'Read-only. Refreshes every ${SystemScreen.refresh.inSeconds}s.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Spacing.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Spacing.sm),
          ...children,
        ]),
      );
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
        title: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}

/// Label, a single-hue bar on a recessive track, and the value in text ink.
class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.frac, required this.value, this.over = false});
  final String label;
  final double frac;
  final String value;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (over) ...[Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error), const SizedBox(width: Spacing.xs)],
          // Both sides shrink with an ellipsis on narrow screens; neither vanishes.
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: Spacing.sm),
          Expanded(
            flex: 2,
            child: Text(
              over ? '$value · high' : value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ]),
        const SizedBox(height: Spacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: frac.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            color: over ? scheme.error : scheme.primary,
          ),
        ),
      ]),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.k, this.v);
  final String k, v;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(children: [
          Expanded(child: Text(k, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium)),
          const SizedBox(width: Spacing.sm),
          Text(v, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}
