import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/domain/session.dart';
import '../data/file_edits_api.dart';
import '../domain/file_edits.dart';
import 'file_diff_screen.dart';
import 'git_sheet.dart';

/// Changed-files list for a session (proposal 20) — a git-status analog over
/// the session's Edit/Write tool calls. Tap a file → its diff.
void showChangedFilesSheet(BuildContext context, Creds creds, Session session) {
  final api = FileEditsApi(dioFor(creds));
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => ChangedFilesList(api: api, creds: creds, session: session, inSheet: true),
  );
}

/// The list itself; also embedded in the desktop workspace's side pane
/// ([inSheet] false: tapping a file pushes its diff without popping first).
class ChangedFilesList extends StatefulWidget {
  const ChangedFilesList({super.key, required this.api, required this.creds, required this.session, this.inSheet = false});

  final FileEditsApi api;
  final Creds creds;
  final Session session;
  final bool inSheet;

  @override
  State<ChangedFilesList> createState() => _ChangedFilesListState();
}

class _ChangedFilesListState extends State<ChangedFilesList> {
  late final Future<List<ChangedFile>> _files = widget.api.changedFiles(widget.session.id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creds = widget.creds, session = widget.session;
    return SafeArea(
      child: FutureBuilder<List<ChangedFile>>(
        future: _files,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Text('Could not load changed files', style: theme.textTheme.bodyMedium),
            );
          }
          if (!snap.hasData) {
            return const SizedBox(height: 200, child: SkeletonList(rows: 3));
          }
          final files = snap.data!;
          if (files.isEmpty) {
            // No Edit/Write calls — but shell commands may still have changed the tree,
            // so committing stays one tap away (the sheet lists the real git status).
            return Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('No files changed', style: theme.textTheme.bodyMedium),
                const SizedBox(height: Spacing.sm),
                TextButton.icon(
                  icon: const Icon(Icons.commit, size: 16),
                  label: const Text('Commit…'),
                  onPressed: () => showGitSheet(context, creds: creds, session: session),
                ),
              ]),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                child: Text('Changed files', style: theme.textTheme.titleSmall),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: files.length,
                  itemBuilder: (context, i) => _FileRow(
                    file: files[i],
                    onTap: () {
                      // Grab the navigator before popping the sheet's own route.
                      final nav = Navigator.of(context);
                      if (widget.inSheet) nav.pop();
                      nav.push(
                        sharedAxisRoute<void>(
                          FileDiffScreen(creds: creds, sessionId: session.id, file: files[i]),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.xs, Spacing.lg, Spacing.sm),
                child: Row(children: [
                  Expanded(
                    // Inherent limit of the tool_json source (proposal 20).
                    child: Text(
                      'Shell-made changes not shown',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.commit, size: 16),
                    label: const Text('Commit…'),
                    onPressed: () => showGitSheet(context, creds: creds, session: session),
                  ),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.onTap});

  final ChangedFile file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slash = file.relPath.lastIndexOf('/');
    final name = slash < 0 ? file.relPath : file.relPath.substring(slash + 1);
    final dir = slash < 0 ? '' : file.relPath.substring(0, slash);
    return ListTile(
      dense: true,
      onTap: onTap,
      title: Text(name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: dir.isEmpty
          ? null
          : Text(dir, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (file.written)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.sm),
              child: Text('written',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          Text('+${file.adds}', style: theme.textTheme.labelSmall?.copyWith(color: Colors.green)),
          const SizedBox(width: Spacing.xs),
          Text('−${file.dels}', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}
