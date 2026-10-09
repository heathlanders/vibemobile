import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../projects/data/git_api.dart';
import '../../sessions/domain/session.dart';
import '../data/file_edits_api.dart';

/// Commit a session's work from the phone (ADR 0024): tick files, write a message,
/// commit. No push. The session's own edits are pre-ticked; everything else in the
/// working tree is listed but opt-in, and secret-looking files can't be ticked.
Future<void> showGitSheet(BuildContext context, {required Creds creds, required Session session}) {
  final dio = dioFor(creds);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => GitSheet(
      api: GitApi(dio),
      sessionId: session.id,
      loadEdited: () async => (await FileEditsApi(dio).changedFiles(session.id)).map((f) => f.relPath).toSet(),
    ),
  );
}

/// Which files start ticked: the session's own edits, minus secrets. Already-staged
/// files are always part of the commit, so they are reported separately. Pure → tested.
@visibleForTesting
Set<String> defaultSelection(List<GitFile> files, Set<String> edited) =>
    {for (final f in files) if (!f.staged && !f.looksSecret && edited.contains(f.path)) f.path};

class GitSheet extends StatefulWidget {
  const GitSheet({super.key, required this.api, required this.sessionId, required this.loadEdited});

  final GitApi api;
  final String sessionId;
  final Future<Set<String>> Function() loadEdited;

  @override
  State<GitSheet> createState() => _GitSheetState();
}

class _GitSheetState extends State<GitSheet> {
  GitStatus? _status;
  Set<String> _selected = {};
  final _message = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    _load(initial: true);
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final status = await widget.api.sessionStatus(widget.sessionId);
      final edited = initial ? await widget.loadEdited() : const <String>{};
      if (!mounted) return;
      setState(() {
        _status = status;
        _selected = initial
            ? defaultSelection(status.files, edited)
            : _selected.intersection({for (final f in status.files) f.path});
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not read the working tree.');
    }
  }

  List<GitFile> get _files => _status?.files ?? const [];
  int get _stagedCount => _files.where((f) => f.staged).length;
  bool get _canCommit => !_busy && _message.text.trim().isNotEmpty && (_selected.isNotEmpty || _stagedCount > 0);

  Future<void> _commit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      if (_selected.isNotEmpty) {
        final s = await widget.api.stage(widget.sessionId, _selected.toList());
        if (!s.ok) return _fail(s.error);
      }
      final c = await widget.api.commit(widget.sessionId, _message.text.trim());
      if (!c.ok) return _fail(c.error);
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('Committed ${c.shortSha} — ${c.subject ?? ''}')));
    } catch (_) {
      _fail('Could not reach the server.');
    }
  }

  void _fail(String? message) {
    if (mounted) {
      setState(() {
        _busy = false;
        _error = message ?? 'Failed.';
      });
    }
  }

  Future<void> _newBranch() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New branch'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'feature/my-change'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create')),
        ],
      ),
    );
    // Not disposed here: the dialog's exit animation is still building its TextField
    // (same pattern as session_actions.dart's _textDialog).
    if (name == null || name.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.branch(widget.sessionId, name.trim());
      if (!r.ok) return _fail(r.error);
      setState(() => _busy = false);
      await _load();
    } catch (_) {
      _fail('Could not reach the server.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('Commit', style: theme.textTheme.titleMedium)),
              if (status != null && status.repo)
                TextButton.icon(
                  onPressed: _busy ? null : _newBranch,
                  icon: const Icon(Icons.call_split, size: 16),
                  label: Text(status.branch ?? 'detached'),
                ),
            ]),
            if (status == null && _error == null) const LinearProgressIndicator(),
            if (status != null && !status.repo)
              Text('This project is not a git repository.', style: theme.textTheme.bodyMedium)
            else if (status != null && _files.isEmpty)
              Text('Nothing to commit — the working tree is clean.', style: theme.textTheme.bodyMedium)
            else if (status != null) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final f in _files) _row(f, theme)],
                ),
              ),
              if (status.truncated)
                Text('List capped — only the first files are shown.', style: theme.textTheme.labelSmall),
              const SizedBox(height: Spacing.sm),
              TextField(
                controller: _message,
                enabled: !_busy,
                minLines: 1,
                maxLines: 4,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Commit message', border: OutlineInputBorder()),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: Spacing.sm),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: Spacing.sm),
              FilledButton(
                onPressed: _canCommit ? _commit : null,
                child: Text(_busy ? 'Working…' : 'Commit'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _row(GitFile f, ThemeData theme) {
    final locked = f.staged || f.looksSecret;
    final note = f.staged
        ? 'already staged'
        : f.looksSecret
            ? 'looks like a secret — not offered'
            : f.untracked
                ? 'new file'
                : null;
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: f.staged || _selected.contains(f.path),
      onChanged: (_busy || locked)
          ? null
          : (v) => setState(() => v == true ? _selected.add(f.path) : _selected.remove(f.path)),
      title: Text(f.path, style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
      subtitle: note == null ? null : Text(note, style: theme.textTheme.labelSmall),
    );
  }
}
