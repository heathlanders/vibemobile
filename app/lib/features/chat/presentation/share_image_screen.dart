import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/data/session_api.dart';
import '../../sessions/domain/session.dart';
import 'chat_screen.dart';

/// Landing for an image shared into the app via the OS share sheet (proposal 16).
/// Pick a live Claude session or spin up a new one in a project; the shared
/// [imageBytes] are then pre-attached to that chat's composer.
class ShareImageScreen extends StatefulWidget {
  const ShareImageScreen({super.key, required this.creds, required this.imageBytes});
  final Creds creds;
  final List<Uint8List> imageBytes;

  @override
  State<ShareImageScreen> createState() => _ShareImageScreenState();
}

class _ShareImageScreenState extends State<ShareImageScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final Future<(List<Session>, List<Project>, Map<String, String>)> _future = _load();
  bool _busy = false;

  Future<(List<Session>, List<Project>, Map<String, String>)> _load() async {
    final sessions = await _api.allSessions();
    final projects = await _api.projects();
    final names = {for (final p in projects) p.id: p.label};
    final liveClaude = sessions.where((s) => s.isLive && s.kind == 'claude').toList();
    return (liveClaude, projects, names);
  }

  Future<void> _openExisting(Session s) => _open(s);

  Future<void> _createIn(Project p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final s = await _api.create(p.id, kind: 'claude');
      await _open(s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Session s) async {
    if (!mounted) return;
    // pushReplacement: Back from chat shouldn't return to this picker.
    await Navigator.of(context).pushReplacement(
      sharedAxisRoute(ChatScreen(creds: widget.creds, session: s, initialImageBytes: widget.imageBytes)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.imageBytes.length;
    return Scaffold(
      appBar: AppBar(title: Text(n == 1 ? 'Share image to…' : 'Share $n images to…')),
      body: FutureBuilder<(List<Session>, List<Project>, Map<String, String>)>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return ErrorBody(message: '${snap.error}');
          final (sessions, projects, names) = snap.data!;
          return ListView(
            children: [
              if (sessions.isNotEmpty) ...[
                const _SectionHeader('Live Claude sessions'),
                for (final s in sessions)
                  ListTile(
                    leading: const Icon(Icons.smart_toy_outlined),
                    title: Text(s.label),
                    subtitle: Text(names[s.projectId] ?? s.projectId),
                    onTap: _busy ? null : () => _openExisting(s),
                  ),
              ],
              const _SectionHeader('New Claude session in…'),
              if (projects.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Spacing.lg),
                  child: Text('No projects found.'),
                ),
              for (final p in projects)
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(p.label),
                  onTap: _busy ? null : () => _createIn(p),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}
