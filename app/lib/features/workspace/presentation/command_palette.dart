import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';

/// Ctrl+K quick-open (ADR 0015): type to filter every openable session across
/// projects (same matcher as session search); Enter or click returns it.
Future<Session?> showCommandPalette(BuildContext context, Creds creds) =>
    showDialog<Session>(context: context, builder: (_) => _CommandPalette(creds: creds));

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.creds});
  final Creds creds;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final Future<(List<Session>, Map<String, String>)> _future = _load();
  String _query = '';

  Future<(List<Session>, Map<String, String>)> _load() async {
    final sessions = await _api.allSessions();
    final projects = await _api.projects();
    return (sessions.where((s) => s.canOpen).toList(), {for (final p in projects) p.id: p.label});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 420),
        child: FutureBuilder<(List<Session>, Map<String, String>)>(
          future: _future,
          builder: (context, snap) {
            final (sessions, names) = snap.data ?? (const <Session>[], const <String, String>{});
            final hits =
                sessions.where((s) => sessionMatches(s, names[s.projectId] ?? s.projectId, _query)).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Open session…',
                    prefixIcon: Icon(Icons.search),
                    border: InputBorder.none,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                  onSubmitted: (_) {
                    if (hits.isNotEmpty) Navigator.pop(context, hits.first);
                  },
                ),
                const Divider(height: 1),
                Flexible(
                  child: switch (snap) {
                    AsyncSnapshot(hasError: true) => ErrorBody(message: '${snap.error}'),
                    AsyncSnapshot(hasData: false) => const SkeletonList(rows: 4),
                    _ when hits.isEmpty => const EmptyState(icon: Icons.search_off_outlined, title: 'No matches'),
                    _ => ListView.builder(
                        shrinkWrap: true,
                        itemCount: hits.length,
                        itemBuilder: (context, i) {
                          final s = hits[i];
                          return ListTile(
                            dense: true,
                            selected: i == 0, // what Enter opens
                            leading: Icon(s.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal),
                            title: Text(s.label, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${names[s.projectId] ?? s.projectId} · ${s.status}'),
                            onTap: () => Navigator.pop(context, s),
                          );
                        },
                      ),
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
