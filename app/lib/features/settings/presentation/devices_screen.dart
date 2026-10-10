import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/admin_api.dart';
import 'pair_device_dialog.dart';

/// Paired devices, with revoke (security.md #4). Until now "lost phone → kill
/// token" meant SSH-ing to the box; this is the same `DELETE /devices/:id` from
/// the phone. Revoking the device you're on signs this app out.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key, required this.creds});
  final Creds creds;

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  late final AdminApi _api = AdminApi(dioFor(widget.creds));
  late Future<List<PairedDevice>> _future = _api.devices();

  void _reload() => setState(() => _future = _api.devices());

  Future<void> _revoke(PairedDevice d) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: Text('Revoke ${d.name}?'),
        content: Text(d.current
            ? 'This is the device you are using. Revoking it signs you out — you’ll need a new pairing code from the server.'
            : 'That device’s token stops working immediately.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Revoke')),
        ],
      ),
    );
    if (confirmed != true) return;

    await _api.revoke(d.id);
    if (!mounted) return;
    if (d.current) {
      await ref.read(tokenStoreProvider).clear();
      ref.invalidate(credsProvider); // app root routes back to pairing
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paired devices')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await showDialog<void>(context: context, builder: (_) => PairDeviceDialog(creds: widget.creds, api: _api));
          if (mounted) _reload(); // the new device shows up once it has paired
        },
        icon: const Icon(Icons.add_link),
        label: const Text('Pair a new device'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<PairedDevice>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) return const SkeletonList(rows: 3);
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            final devices = snap.data ?? [];
            if (devices.isEmpty) {
              return const EmptyState(icon: Icons.devices_other_outlined, title: 'No paired devices');
            }
            return ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, i) {
                final d = devices[i];
                return ListTile(
                  leading: Icon(d.current ? Icons.smartphone : Icons.devices_other_outlined),
                  title: Row(children: [
                    Flexible(child: Text(d.name, overflow: TextOverflow.ellipsis)),
                    if (d.current) ...[
                      const SizedBox(width: Spacing.sm),
                      const Chip(label: Text('This device'), visualDensity: VisualDensity.compact),
                    ],
                  ]),
                  subtitle: Text([
                    if (d.pairedAt != null) 'paired ${_day(d.pairedAt!)}',
                    if (d.lastSeen != null) 'seen ${_day(d.lastSeen!)}',
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: 'Revoke',
                    icon: const Icon(Icons.link_off),
                    onPressed: () => _revoke(d),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// "2026-08-07T10:11:12Z" → "2026-08-07"; the raw string when unparseable.
  static String _day(String ts) => DateTime.tryParse(ts)?.toLocal().toString().split(' ').first ?? ts;
}
