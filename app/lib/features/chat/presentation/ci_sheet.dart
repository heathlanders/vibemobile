import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../data/ci_api.dart';
import '../domain/ci_status.dart';

/// "Pull request & CI" (proposal 45): where this chat's branch stands on GitHub. Read-only.
Future<void> showCiSheet(BuildContext context, {required Creds creds, required String sessionId}) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.75, child: CiSheet(load: () => CiApi(dioFor(creds)).status(sessionId))),
    );

class CiSheet extends StatefulWidget {
  const CiSheet({super.key, required this.load, this.open});
  final Future<CiStatus> Function() load;

  /// Opens a URL; tests replace it. Default: the external browser, never an in-app view.
  final Future<void> Function(String url)? open;

  @override
  State<CiSheet> createState() => _CiSheetState();
}

class _CiSheetState extends State<CiSheet> {
  late Future<CiStatus> _f = _load();

  Future<CiStatus> _load() => widget.load().catchError((_) => const CiStatus(available: false, reason: 'could not reach the server'));

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return;
    if (widget.open != null) return widget.open!(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: FutureBuilder<CiStatus>(
        future: _f,
        builder: (context, snap) {
          final s = snap.data;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.xs),
              child: Row(children: [
                Expanded(child: Text('Pull request & CI', style: theme.textTheme.titleMedium)),
                IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _f = _load())),
              ]),
            ),
            if (s == null)
              const Padding(padding: EdgeInsets.all(Spacing.xl), child: Center(child: CircularProgressIndicator()))
            else if (!s.available)
              Padding(padding: const EdgeInsets.all(Spacing.lg), child: Text('Not available: ${s.reason}.', style: theme.textTheme.bodyMedium))
            else
              Expanded(child: ListView(padding: const EdgeInsets.only(bottom: Spacing.lg), children: _body(s, theme))),
          ]);
        },
      ),
    );
  }

  List<Widget> _body(CiStatus s, ThemeData theme) {
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    Widget row(CiCheck c) => ListTile(
          dense: true,
          leading: Icon(_icon(c.state), color: _color(c.state, scheme), size: 20),
          title: Text(c.name, overflow: TextOverflow.ellipsis),
          subtitle: Text(_stateWord(c.state), style: muted),
          trailing: c.url == null ? null : const Icon(Icons.open_in_new, size: 16),
          onTap: c.url == null ? null : () => _open(c.url!),
        );
    final pr = s.pr;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Text('${s.repo} · ${s.branch}', style: muted),
      ),
      const SizedBox(height: Spacing.sm),
      if (pr != null)
        ListTile(
          leading: const Icon(Icons.merge_type),
          title: Text('#${pr.number} ${pr.title}'),
          subtitle: Text([pr.stateLabel, ?pr.reviewLabel, ?pr.mergeLabel].join(' · '), style: muted),
          trailing: pr.url.isEmpty ? null : const Icon(Icons.open_in_new, size: 16),
          onTap: pr.url.isEmpty ? null : () => _open(pr.url),
        )
      else
        Padding(padding: const EdgeInsets.symmetric(horizontal: Spacing.lg), child: Text('No pull request for this branch.', style: theme.textTheme.bodyMedium)),
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.xs),
        child: Text(pr != null ? 'Checks' : 'Latest workflow runs', style: theme.textTheme.titleSmall),
      ),
      if ((pr != null ? s.checks : s.runs).isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: Spacing.lg), child: Text(pr != null ? 'No checks reported.' : 'No runs for this branch.', style: muted))
      else
        for (final c in (pr != null ? s.checks : s.runs)) row(c),
    ];
  }

  static IconData _icon(String state) => switch (state) {
        'passing' => Icons.check_circle_outline,
        'failing' => Icons.cancel_outlined,
        'skipped' => Icons.remove_circle_outline,
        _ => Icons.hourglass_empty,
      };

  static Color? _color(String state, ColorScheme c) => switch (state) {
        'passing' => c.primary,
        'failing' => c.error,
        _ => c.onSurfaceVariant,
      };

  static String _stateWord(String state) => switch (state) {
        'passing' => 'Passed',
        'failing' => 'Failed',
        'skipped' => 'Skipped',
        _ => 'Running or waiting',
      };
}
