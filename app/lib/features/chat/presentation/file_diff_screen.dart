import 'package:flutter/material.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../data/file_edits_api.dart';
import '../domain/file_edits.dart';
import 'diff_lines.dart';

/// One edited file's git-style view (proposal 20): the session's diff sections,
/// toggleable to the current on-disk content. The server builds both — this
/// screen only colors prefixed lines.
class FileDiffScreen extends StatefulWidget {
  const FileDiffScreen({super.key, required this.creds, required this.sessionId, required this.file});

  final Creds creds;
  final String sessionId;
  final ChangedFile file;

  @override
  State<FileDiffScreen> createState() => _FileDiffScreenState();
}

enum _View { diff, file }

class _FileDiffScreenState extends State<FileDiffScreen> {
  late final FileEditsApi _api;
  late final Future<FileDiff> _diff;
  Future<FileContent?>? _content; // lazy — only fetched when toggled
  _View _view = _View.diff;

  @override
  void initState() {
    super.initState();
    _api = FileEditsApi(dioFor(widget.creds));
    _diff = _api.diff(widget.sessionId, widget.file.path);
  }

  void _setView(_View v) {
    setState(() {
      _view = v;
      if (v == _View.file) _content ??= _api.content(widget.sessionId, widget.file.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.file.relPath, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: SegmentedButton<_View>(
              segments: const [
                ButtonSegment(value: _View.diff, label: Text('Diff')),
                ButtonSegment(value: _View.file, label: Text('File')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => _setView(s.first),
            ),
          ),
          Expanded(child: _view == _View.diff ? _DiffView(diff: _diff) : _FileView(content: _content!)),
        ],
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});
  final Future<FileDiff> diff;

  /// "2026-07-24T14:32:05.123Z" → "14:32" (local); '' when unparseable.
  static String _time(String ts) {
    final t = DateTime.tryParse(ts)?.toLocal();
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<FileDiff>(
      future: diff,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Could not load diff', style: theme.textTheme.bodyMedium));
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final edits = snap.data!.edits;
        // Flatten to rows: a header per edit section, then its colored lines.
        final rows = <Widget>[];
        for (var i = 0; i < edits.length; i++) {
          final e = edits[i];
          final time = _time(e.ts);
          rows.add(Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.xs),
            child: Text(
              '${e.tool == 'Write' ? 'Written' : 'Edit ${i + 1}'}'
              '${e.replaceAll ? ' (replace all)' : ''}'
              '${time.isEmpty ? '' : ' · $time'}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ));
          for (final line in e.diff.split('\n')) {
            rows.add(DiffLine(line: line));
          }
        }
        return SelectionArea(
          child: ListView(padding: const EdgeInsets.only(bottom: Spacing.lg), children: rows),
        );
      },
    );
  }
}

class _FileView extends StatelessWidget {
  const _FileView({required this.content});
  final Future<FileContent?> content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<FileContent?>(
      future: content,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(child: Text('Could not load file', style: theme.textTheme.bodyMedium));
        }
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final file = snap.data;
        if (file == null) {
          // 404 deleted-since-edit / 415 binary / 403 out of scope.
          return Center(child: Text('File not viewable (deleted or binary)', style: theme.textTheme.bodyMedium));
        }
        return Column(
          children: [
            if (file.truncated)
              Container(
                width: double.infinity,
                color: theme.colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs, horizontal: Spacing.md),
                child: Text('Truncated — showing the first part of a large file',
                    style: theme.textTheme.labelSmall),
              ),
            Expanded(
              child: SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: SizedBox(width: double.infinity, child: Text(file.content, style: monoStyle(context))),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
