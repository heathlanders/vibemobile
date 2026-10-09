import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/admin_api.dart';

/// The `events` audit log (security.md #5/#14) — every permission decision,
/// session lifecycle change, project write and auth event the daemon recorded.
/// Read-only: there is no mutating endpoint, by design.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

/// Filter chips map to the `kind` prefixes the daemon writes.
const _filters = <String, String>{
  'permission': 'Permissions',
  'session': 'Sessions',
  'project': 'Projects',
  'auth': 'Auth',
  'device': 'Devices',
};

class _AuditLogScreenState extends State<AuditLogScreen> {
  late final AdminApi _api = AdminApi(dioFor(widget.creds));
  String? _kind;
  late Future<List<AuditEvent>> _future = _api.events();

  void _reload() => setState(() => _future = _api.events(kind: _kind));

  void _setKind(String? k) {
    _kind = k;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audit log')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
            child: Row(children: [
              for (final e in _filters.entries)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.sm),
                  child: FilterChip(
                    label: Text(e.value),
                    selected: _kind == e.key,
                    onSelected: (sel) => _setKind(sel ? e.key : null),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: FutureBuilder<List<AuditEvent>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) return const SkeletonList();
                  if (snap.hasError) return ErrorBody(message: '${snap.error}');
                  final events = snap.data ?? [];
                  if (events.isEmpty) {
                    return const EmptyState(icon: Icons.receipt_long_outlined, title: 'No events');
                  }
                  return ListView.builder(
                    itemCount: events.length,
                    itemBuilder: (context, i) => _EventRow(event: events[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final AuditEvent event;

  /// Denials and failures are the rows worth spotting at a glance.
  bool get _notable =>
      event.kind.endsWith('.deny') || event.kind.endsWith('.fail') || event.kind.endsWith('.reject');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        _notable ? Icons.gpp_bad_outlined : Icons.check_circle_outline,
        size: 18,
        color: _notable ? theme.colorScheme.error : theme.colorScheme.outline,
      ),
      title: Text(event.kind, style: theme.textTheme.bodyMedium),
      subtitle: event.detail == null || event.detail!.isEmpty
          ? null
          : Text(
              event.detail!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: AppTheme.monoFontFamily),
            ),
      trailing: Text(_time(event.ts), style: theme.textTheme.labelSmall),
    );
  }

  /// "…T14:32:05Z" → "14:32" (local); the date when it isn't today.
  static String _time(String ts) {
    final t = DateTime.tryParse(ts)?.toLocal();
    if (t == null) return '';
    final now = DateTime.now();
    final hhmm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? hhmm : '${t.month}/${t.day}';
  }
}
