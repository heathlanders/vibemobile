import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../notes/presentation/notes_panel.dart';
import '../../projects/data/git_api.dart';
import '../../prompts/data/prompt_api.dart';
import '../../prompts/domain/prompt.dart';
import '../../prompts/presentation/prompt_use_screen.dart';
import '../../terminal/presentation/terminal_screen.dart';
import '../data/session_api.dart';
import '../domain/session.dart';
import 'model_picker.dart';
import 'session_actions.dart';

/// One project's sessions: list them, start a terminal or Claude session, tap to
/// open. (Extracted from the M2 picker; the dashboard navigates here.)
class ProjectSessionsScreen extends StatefulWidget {
  const ProjectSessionsScreen({super.key, required this.creds, required this.project});
  final Creds creds;
  final Project project;

  @override
  State<ProjectSessionsScreen> createState() => _ProjectSessionsScreenState();
}

class _ProjectSessionsScreenState extends State<ProjectSessionsScreen> {
  late final SessionApi _api = SessionApi(dioFor(widget.creds));
  late final GitApi _git = GitApi(dioFor(widget.creds));
  late Future<List<Session>> _future = _api.sessions(widget.project.id);
  late Future<GitStatus> _status = _git.status(widget.project.id);
  late final Future<List<AgentPreset>> _presets = _api.presets().catchError((_) => <AgentPreset>[]);
  bool _creating = false;
  String? _tagFilter; // when set, only sessions carrying this tag show (proposal 12)

  void _reload() => setState(() {
        _future = _api.sessions(widget.project.id);
        _status = _git.status(widget.project.id);
      });

  Future<void> _openSession(Session s) async {
    final Widget screen = s.kind == 'claude'
        ? ChatScreen(creds: widget.creds, session: s)
        : TerminalScreen(creds: widget.creds, session: s);
    await Navigator.of(context).push(sharedAxisRoute(screen));
    if (mounted) _reload(); // a Close in the session deletes it
  }

  // Long-press menu for a single session.
  Future<void> _sessionActions(Session s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Edit tags'),
              onTap: () => Navigator.pop(ctx, 'tags'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy session ID'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Kill session', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'kill'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _rename(s);
      case 'tags':
        await _editTags(s);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: s.id));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Session ID copied')));
      case 'kill':
        await _kill(s);
    }
  }

  Future<void> _rename(Session s) async {
    if (await renameSession(context, _api, s)) _reload();
  }

  Future<void> _editTags(Session s) async {
    if (await editSessionTags(context, _api, s)) _reload();
  }

  Future<void> _kill(Session s) async {
    if (await killSession(context, _api, s)) _reload();
  }

  // Bulk-clear stale sessions: all of them, or only those older than a week.
  // Transcripts stay on disk, so `claude --resume` still works from the CLI.
  Future<void> _pruneStale(int? olderThanDays) async {
    final stale = (await _future).where((s) => s.status == 'stale' && s.externalStatus == null).length;
    if (!mounted) return;
    final scope = olderThanDays == null ? 'All stale sessions' : 'Stale sessions older than $olderThanDays days';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear stale sessions?'),
        content: Text('$scope ($stale stale in this project) will be removed from the app. '
            'Their transcripts stay on the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final n = await _api.pruneStale(widget.project.id, olderThanDays: olderThanDays);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cleared $n stale sessions')));
      _reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _create(String kind, {String? model, String? preset, bool worktree = false}) async {
    setState(() => _creating = true);
    try {
      final s = await _api.create(widget.project.id, kind: kind, model: model, preset: preset, worktree: worktree);
      if (mounted) await _openSession(s);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  // New Claude session: pick a model first (ADR 0007), then create. With no
  // gateway configured the daemon returns a single "default" entry — the picker
  // is skipped and the flow is unchanged for solo Claude.
  Future<void> _newClaude({bool worktree = false}) async {
    setState(() => _creating = true);
    final choice = await chooseModel(context, _api);
    if (mounted) setState(() => _creating = false);
    if (choice == null || !mounted) return; // cancelled / list failed
    await _create('claude', model: choice.id, worktree: worktree);
  }

  // Session templates (proposal 04): pick a `template`-tagged prompt (global or
  // this project's), then fill vars on the prompt-use screen with "new session
  // in this project" preselected — the daemon primes it as the first turn.
  Future<void> _fromTemplate() async {
    final List<Prompt> templates;
    try {
      templates = templatesOf(await PromptApi(dioFor(widget.creds)).list(projectId: widget.project.id));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Prompt>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: templates.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(Spacing.xl),
                child: Text('No templates yet. Tag a prompt "template" in the prompt library to list it here.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final t in templates)
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(t.title),
                      subtitle: Text(t.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(ctx, t),
                    ),
                ],
              ),
      ),
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(sharedAxisRoute(
      PromptUseScreen(creds: widget.creds, prompt: picked, initialTarget: 'new:${widget.project.id}'),
    ));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.label),
        actions: [
          IconButton(
            tooltip: 'Notes',
            icon: const Icon(Icons.sticky_note_2_outlined),
            onPressed: () => showProjectNotes(context, widget.creds, widget.project),
          ),
          IconButton(
            tooltip: 'Start from template',
            icon: const Icon(Icons.description_outlined),
            onPressed: _creating ? null : _fromTemplate,
          ),
          // Agent CLIs installed on the server (ADR 0016); hidden when none.
          FutureBuilder<List<AgentPreset>>(
            future: _presets,
            builder: (context, snap) {
              final presets = snap.data ?? const <AgentPreset>[];
              if (presets.isEmpty) return const SizedBox.shrink();
              return PopupMenuButton<AgentPreset>(
                tooltip: 'Start an agent CLI',
                icon: const Icon(Icons.rocket_launch_outlined),
                enabled: !_creating,
                onSelected: (p) => _create('terminal', preset: p.id),
                itemBuilder: (_) => [for (final p in presets) PopupMenuItem(value: p, child: Text(p.label))],
              );
            },
          ),
          PopupMenuButton<int>(
            tooltip: 'Clear stale sessions',
            icon: const Icon(Icons.cleaning_services_outlined),
            onSelected: (days) => _pruneStale(days < 0 ? null : days),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Clear stale older than 7 days')),
              PopupMenuItem(value: -1, child: Text('Clear all stale')),
            ],
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'new-claude',
            onPressed: _creating ? null : _newClaude,
            icon: const Icon(Icons.smart_toy_outlined),
            label: const Text('New Claude'),
          ),
          const SizedBox(height: 12),
          // Own git worktree + branch: parallel Claudes don't trample one checkout (ADR 0022).
          FloatingActionButton.extended(
            heroTag: 'new-claude-isolated',
            onPressed: _creating ? null : () => _newClaude(worktree: true),
            icon: const Icon(Icons.call_split),
            label: const Text('New isolated Claude'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'new-terminal',
            onPressed: _creating ? null : () => _create('terminal'),
            icon: const Icon(Icons.terminal),
            label: const Text('New terminal'),
          ),
        ],
      ),
      body: Column(
        children: [
          _GitStrip(status: _status),
          Expanded(child: _sessionList()),
        ],
      ),
    );
  }

  Widget _sessionList() {
    return RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<Session>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SkeletonList();
            }
            if (snap.hasError) return ErrorBody(message: '${snap.error}');
            final all = snap.data ?? [];
            if (all.isEmpty) {
              return const EmptyState(
                icon: Icons.terminal_outlined,
                title: 'No sessions yet',
                hint: 'Tap “New terminal” or “New Claude” to start one.',
              );
            }
            final allTags = {for (final s in all) ...s.tags}.toList()..sort();
            // Drop a stale filter if its tag no longer exists on any session.
            if (_tagFilter != null && !allTags.contains(_tagFilter)) _tagFilter = null;
            final sessions = _tagFilter == null ? all : all.where((s) => s.tags.contains(_tagFilter)).toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (allTags.isNotEmpty)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
                    child: Row(
                      children: [
                        for (final t in allTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              label: Text(t),
                              selected: _tagFilter == t,
                              onSelected: (sel) => setState(() => _tagFilter = sel ? t : null),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      return ListTile(
                        leading: Icon(s.kind == 'claude'
                            ? Icons.smart_toy_outlined
                            : (s.isLive ? Icons.terminal : Icons.terminal_outlined)),
                        title: Text(s.label),
                        subtitle: s.tags.isEmpty
                            ? Text(_meta(s))
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_meta(s)),
                                  const SizedBox(height: Spacing.xs),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: [for (final t in s.tags) _TagChip(t)],
                                  ),
                                ],
                              ),
                        onTap: s.canOpen ? () => _openSession(s) : null,
                        onLongPress: () => _sessionActions(s), // rename / tags / copy id / kill
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      );
  }
}

/// Working-tree state for the project (ADR 0011) — read-only: branch,
/// ahead/behind and the changed-file count, tap for the paths. Hidden entirely
/// when the project isn't a git repo, so nothing new appears for non-repos.
class _GitStrip extends StatelessWidget {
  const _GitStrip({required this.status});
  final Future<GitStatus> status;

  void _showFiles(BuildContext context, GitStatus s) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final f in s.files)
              ListTile(
                dense: true,
                leading: Icon(f.untracked ? Icons.add_circle_outline : Icons.edit_outlined, size: 18),
                title: Text(
                  f.path,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: AppTheme.monoFontFamily),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (s.truncated)
              const ListTile(dense: true, title: Text('More changes than shown (server cap)')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<GitStatus>(
      future: status,
      builder: (context, snap) {
        final s = snap.data;
        // No data yet, request failed, or not a repo → show nothing at all.
        if (s == null || !s.repo) return const SizedBox.shrink();
        return InkWell(
          onTap: s.clean ? null : () => _showFiles(context, s),
          child: Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
            child: Row(children: [
              Icon(s.clean ? Icons.check_circle_outline : Icons.edit_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(s.summary, style: theme.textTheme.bodySmall)),
              if (!s.clean) Icon(Icons.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
            ]),
          ),
        );
      },
    );
  }
}

/// Session row metadata line: kind · status, plus spend when there is any
/// (native/pay-per-token sessions only).
String _meta(Session s) => [
      s.kind,
      s.externalStatus != null ? 'on PC' : s.status,
      if (s.worktreeBranch != null) 'isolated · ${s.worktreeBranch}',
      s.costLabel,
    ].where((p) => p.isNotEmpty).join(' · ');

/// A compact read-only tag label on a session tile (proposal 12).
class _TagChip extends StatelessWidget {
  const _TagChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(Radii.sm)),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
