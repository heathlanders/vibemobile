import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../chat/presentation/diff_lines.dart';
import '../../chat/presentation/markdown_text.dart';
import '../../files/data/project_files_api.dart';
import '../../files/presentation/file_download.dart';
import '../domain/editor_doc.dart';
import '../domain/line_diff.dart';
import 'code_view.dart';
import 'editor_controller.dart';

/// Open, edit and save one text file (proposal 60). [readOnly] is for places that replace a viewer.
/// [embedded] (a desktop workspace tab) drops the back button and the leave-confirm: the tab strip
/// owns closing.
class CodeEditorScreen extends ConsumerWidget {
  const CodeEditorScreen({super.key, required this.api, required this.path, this.line, this.readOnly = false, this.embedded = false});
  final ProjectFilesApi api;
  final String path;
  final int? line;
  final bool readOnly;
  final bool embedded;

  EditorTarget get target => EditorTarget(api, path, line: line, readOnly: readOnly);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(editorDocProvider(target));
    final name = path.split('/').last;
    switch (doc.status) {
      case EditorStatus.ready:
        return _EditorPane(key: ValueKey(doc.gen), target: target, embedded: embedded);
      case EditorStatus.loading:
        return Scaffold(appBar: _bar(name), body: const Center(child: CircularProgressIndicator()));
      case EditorStatus.failed:
        return Scaffold(appBar: _bar(name), body: _FailureBody(api: api, path: path, doc: doc));
    }
  }

  AppBar _bar(String name) => AppBar(automaticallyImplyLeading: !embedded, title: Text(name, overflow: TextOverflow.ellipsis));
}

class _FailureBody extends StatelessWidget {
  const _FailureBody({required this.api, required this.path, required this.doc});
  final ProjectFilesApi api;
  final String path;
  final EditorDoc doc;

  @override
  Widget build(BuildContext context) {
    final (message, download) = switch (doc.failure) {
      EditorFailure.tooLarge => ('This file is too large to open in the editor.', true),
      EditorFailure.binary => ('This is a binary file (or not UTF-8), so it can\'t be edited here.', true),
      EditorFailure.forbidden => ('This file isn\'t available: it looks like a secret (keys, credentials, .env) or is outside the project.', false),
      _ => (doc.error ?? 'Could not open the file', false),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center),
          if (download) ...[
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download'),
              onPressed: () => downloadProjectFile(context, api, path),
            ),
          ],
        ]),
      ),
    );
  }
}

enum _Conflict { reload, overwrite, diff }

class _EditorPane extends ConsumerStatefulWidget {
  const _EditorPane({super.key, required this.target, required this.embedded});
  final EditorTarget target;
  final bool embedded;

  @override
  ConsumerState<_EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends ConsumerState<_EditorPane> {
  late final CodeLineEditingController _controller;
  late final CodeFindController _find;
  late CodeLines _lastLines;
  bool _preview = false;

  EditorTarget get _t => widget.target;
  EditorDocNotifier get _notifier => ref.read(editorDocProvider(_t).notifier);

  @override
  void initState() {
    super.initState();
    _controller = codeController(ref.read(editorDocProvider(_t)).content);
    _find = CodeFindController(_controller);
    _lastLines = _controller.codeLines;
    if (!_t.readOnly) _controller.addListener(_onChange);
  }

  /// Any edit marks the file dirty (selection moves leave `codeLines` as it was).
  void _onChange() {
    final lines = _controller.codeLines;
    if (identical(lines, _lastLines)) return;
    _lastLines = lines;
    _notifier.setDirty(true);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    _find.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _say(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _save({String? baseSha}) async {
    final doc = ref.read(editorDocProvider(_t));
    if (_t.readOnly || doc.saving) return;
    final out = await _notifier.save(_controller.text, baseSha: baseSha);
    if (!mounted) return;
    switch (out) {
      case Saved():
        _lastLines = _controller.codeLines;
        _say('Saved');
      case SaveFailed(:final message):
        _say(message);
      case SaveConflict(:final sha):
        await _conflict(sha);
    }
  }

  /// 409: the file changed on the server since it was opened.
  Future<void> _conflict(String? serverSha) async {
    while (true) {
      if (!mounted) return;
      final choice = await showDialog<_Conflict>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('File changed on the server'),
          content: const Text('It was modified after you opened it. Reload discards your edits; Overwrite saves yours over it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, _Conflict.diff), child: const Text('Show diff')),
            TextButton(onPressed: () => Navigator.pop(ctx, _Conflict.reload), child: const Text('Reload')),
            FilledButton(onPressed: () => Navigator.pop(ctx, _Conflict.overwrite), child: const Text('Overwrite')),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      switch (choice) {
        case _Conflict.reload:
          await _notifier.load(); // a new generation rebuilds this pane around the server's text
          return;
        case _Conflict.overwrite:
          if (serverSha == null) return _say('Could not tell what changed; reload and try again');
          return _save(baseSha: serverSha);
        case _Conflict.diff:
          await _showDiff();
      }
    }
  }

  Future<void> _showDiff() async {
    final TextDoc server;
    try {
      server = await _t.api.readDoc(_t.path);
    } catch (_) {
      return _say('Could not load the server\'s copy');
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _DiffScreen(name: _t.path.split('/').last, lines: lineDiff(server.content, _controller.text))));
  }

  /// Leave-confirm for the pushed route: a dirty buffer asks before the screen goes.
  Future<void> _confirmLeave() async {
    final nav = Navigator.of(context);
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    if (leave == true) nav.pop();
  }

  bool get _canPreview => const {'markdown', 'json'}.contains(ref.read(editorDocProvider(_t)).language);

  Widget _previewBody() {
    final text = _controller.text;
    if (ref.read(editorDocProvider(_t)).language == 'markdown') {
      return SingleChildScrollView(padding: const EdgeInsets.all(Spacing.lg), child: MarkdownText(text));
    }
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      pretty = text; // not valid JSON (yet): show it as written
    }
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(Spacing.md),
        child: SelectableText(pretty, style: const TextStyle(fontFamily: AppTheme.monoFontFamily, fontSize: 13, height: 1.4)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(editorDocProvider(_t));
    final theme = Theme.of(context);
    final name = _t.path.split('/').last;
    final scaffold = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Tooltip(
          message: _t.path,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
            if (doc.dirty) ...[
              const SizedBox(width: Spacing.sm),
              Container(key: const ValueKey('dirty-dot'), width: 8, height: 8, decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle)),
            ],
          ]),
        ),
        actions: [
          if (_canPreview)
            IconButton(
              tooltip: _preview ? 'Edit' : 'Preview',
              icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _preview = !_preview),
            ),
          if (_t.readOnly)
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _controller.text));
                _say('Copied');
              },
            ),
          // A phone has Find in the toolbar under the editor.
          if (!phoneToolbar) IconButton(tooltip: 'Find', icon: const Icon(Icons.search), onPressed: _preview ? null : _find.findMode),
          if (!_t.readOnly)
            IconButton(
              tooltip: 'Save',
              icon: doc.saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
              onPressed: doc.dirty && !doc.saving ? _save : null,
            ),
        ],
      ),
      body: IndexedStack(index: _preview ? 1 : 0, children: [
        CodeView(controller: _controller, language: doc.language, readOnly: _t.readOnly, line: _t.line, onSave: _save, findController: _find),
        _preview ? _previewBody() : const SizedBox.shrink(),
      ]),
    );
    if (widget.embedded) return scaffold;
    return PopScope(
      canPop: !doc.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: scaffold,
    );
  }
}

/// Read-only: what would change if the buffer replaced the server's copy.
class _DiffScreen extends StatelessWidget {
  const _DiffScreen({required this.name, required this.lines});
  final String name;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Server vs yours: $name', overflow: TextOverflow.ellipsis)),
        body: lines.isEmpty
            ? const Center(child: Text('No differences'))
            : SelectionArea(child: ListView(padding: const EdgeInsets.only(bottom: Spacing.lg), children: [for (final l in lines) DiffLine(line: l)])),
      );
}
