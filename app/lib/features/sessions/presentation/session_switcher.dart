import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/session_api.dart';
import '../domain/session.dart';

/// Jump between live sessions across all projects.
class SessionSwitcherScreen extends StatefulWidget {
  const SessionSwitcherScreen({super.key, required this.creds});
  final Creds creds;

  @override
  State<SessionSwitcherScreen> createState() => _SessionSwitcherScreenState();
}

class _SessionSwitcherScreenState extends State<SessionSwitcherScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late Future<(List<Session>, Map<String, String>)> _future = _load();

  Future<(List<Session>, Map<String, String>)> _load() async {
    final sessions = await _api.allSessions();
    final projects = await _api.projects();
    final names = {for (final p in projects) p.id: p.label};
    return (sessions.where((s) => s.isLive).toList(), names);
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
      appBar: AppBar(title: const Text('Live sessions')),
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _future = _load()),
        child: FutureBuilder<(List<Session>, Map<String, String>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SkeletonList();
            }
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            final (sessions, names) = snap.data!;
            if (sessions.isEmpty) {
              return const EmptyState(
                icon: Icons.dynamic_feed_outlined,
                title: 'No live sessions',
                hint: 'Open a project and start a terminal or Claude session.',
              );
            }
            return ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, i) {
                final s = sessions[i];
                return ListTile(
                  leading: Icon(s.kind == 'claude' ? Icons.smart_toy_outlined : Icons.terminal),
                  title: Text(s.label),
                  subtitle: Text([names[s.projectId] ?? s.projectId, s.kind, s.costLabel]
                      .where((p) => p.isNotEmpty)
                      .join(' · ')),
                  onTap: () => _open(s),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
