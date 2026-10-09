import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/session_api.dart';
import '../domain/session.dart';

/// Find any session across all projects by free text (project / title / kind /
/// status). Distinct from the live-only switcher: this includes dead/stale rows.
class SessionSearchScreen extends StatefulWidget {
  const SessionSearchScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<SessionSearchScreen> createState() => _SessionSearchScreenState();
}

class _SessionSearchScreenState extends State<SessionSearchScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late Future<(List<Session>, Map<String, String>)> _future = _load();
  String _query = '';

  Future<(List<Session>, Map<String, String>)> _load() async {
    final sessions = await _api.allSessions();
    final projects = await _api.projects();
    return (sessions, {for (final p in projects) p.id: p.label});
  }

  Future<void> _open(Session s) async {
    final Widget screen = s.kind == 'claude'
        ? ChatScreen(creds: widget.creds, session: s)
        : TerminalScreen(creds: widget.creds, session: s);
    await Navigator.of(context).push(sharedAxisRoute(screen));
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search sessions', border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: FutureBuilder<(List<Session>, Map<String, String>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SkeletonList();
          }
          if (snap.hasError) return ErrorBody(message: '${snap.error}');
          final (sessions, names) = snap.data!;
          final hits = sessions
              .where((s) => sessionMatches(s, names[s.projectId] ?? s.projectId, _query))
              .toList();
          if (hits.isEmpty) {
            return const EmptyState(icon: Icons.search_off_outlined, title: 'No matching sessions');
          }
          return ListView.builder(
            itemCount: hits.length,
            itemBuilder: (context, i) {
              final s = hits[i];
              return ListTile(
                enabled: s.canOpen,
                leading: Icon(s.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal),
                title: Text(s.label),
                subtitle: Text('${names[s.projectId] ?? s.projectId} · ${s.kind} · ${s.status}'),
                onTap: s.canOpen ? () => _open(s) : null,
              );
            },
          );
        },
      ),
    );
  }
}
