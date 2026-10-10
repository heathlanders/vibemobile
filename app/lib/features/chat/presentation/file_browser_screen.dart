import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../data/browse_api.dart';

/// Read-only browser for a chat's checkout (proposal 46): folders, text files, nothing else.
/// Back goes up a folder before it leaves the screen.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, required this.sessionId, this.creds, this.api});
  final String sessionId;
  final Creds? creds;

  /// Tests inject a fake; production builds one from [creds].
  final BrowseApi? api;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late final BrowseApi _api = widget.api ?? BrowseApi(dioFor(widget.creds!));
  String _path = '';
  BrowseListing? _listing;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _go('');
  }

  Future<void> _go(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await _api.list(widget.sessionId, path);
      if (mounted) {
        setState(() {
          _path = l.path;
          _listing = l;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  String get _parent => _path.contains('/') ? _path.substring(0, _path.lastIndexOf('/')) : '';

  String _join(String name) => _path.isEmpty ? name : '$_path/$name';

  Future<void> _open(BrowseEntry e) async {
    if (e.isDir) return _go(_join(e.name));
    if (!e.readable) {
      final why = e.type == 'link' ? 'This link points outside the project, so it isn\'t shown.' : 'This looks like a secret (keys, credentials, .env), so it isn\'t shown.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    await Navigator.of(context).push(sharedAxisRoute(FileViewerScreen(path: _join(e.name), load: () => _api.read(widget.sessionId, _join(e.name)))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = _listing;
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(_parent);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_path.isEmpty ? 'Files' : _path, overflow: TextOverflow.ellipsis),
          actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _go(_path))],
        ),
        body: _error != null
            ? ErrorBody(message: _error!)
            : l == null
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    if (_loading) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: l.entries.isEmpty
                          ? const Center(child: Text('Empty folder'))
                          : ListView(children: [
                              if (_path.isNotEmpty) ListTile(dense: true, leading: const Icon(Icons.arrow_upward), title: const Text('..'), onTap: () => _go(_parent)),
                              for (final e in l.entries)
                                ListTile(
                                  dense: true,
                                  leading: Icon(
                                    e.isDir ? Icons.folder_outlined : (e.type == 'link' ? Icons.link_off : (e.readable ? Icons.description_outlined : Icons.lock_outline)),
                                    color: e.readable ? null : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  title: Text(e.name, overflow: TextOverflow.ellipsis, style: e.readable ? null : TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                                  subtitle: e.isDir || e.size == null ? null : Text(sizeLabel(e.size), style: theme.textTheme.bodySmall),
                                  onTap: () => _open(e),
                                ),
                              if (l.truncated)
                                Padding(padding: const EdgeInsets.all(Spacing.lg), child: Text('Only the first ${l.entries.length} entries are shown.', style: theme.textTheme.bodySmall)),
                            ]),
                    ),
                  ]),
      ),
    );
  }
}

/// Opens a file named in chat (proposal 48) in [FileViewerScreen]. The only request it can make is
/// browse/file for [sessionId] (the daemon confines, hides secrets, refuses binaries); refusals
/// become a snackbar. Nothing is launched outside the app.
Future<void> openChatFile(
  BuildContext context, {
  required String sessionId,
  required String path,
  int? line,
  Creds? creds,
  BrowseApi? api,
}) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  void say(String m) => messenger.showSnackBar(SnackBar(content: Text(m)));
  try {
    final f = await (api ?? BrowseApi(dioFor(creds!))).read(sessionId, path);
    if (!context.mounted) return;
    await nav.push(sharedAxisRoute(FileViewerScreen(path: f.path, line: line, load: () async => f)));
  } on BrowseError catch (e) {
    say(switch (e.status) {
      403 => 'Not in this project',
      404 => 'File not found',
      415 => 'Binary file',
      _ => 'Could not open the file',
    });
  } catch (_) {
    say('Could not open the file');
  }
}

/// A text file, read-only: monospace, selectable, scrolls both ways, copy button. With [line]
/// (1-based) the view scrolls there and highlights it.
class FileViewerScreen extends StatelessWidget {
  const FileViewerScreen({super.key, required this.path, required this.load, this.line});
  final String path;
  final Future<BrowseFile> Function() load;
  final int? line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<BrowseFile>(
      future: load(),
      builder: (context, snap) {
        final f = snap.data;
        final err = snap.error;
        return Scaffold(
          appBar: AppBar(
            title: Text(path.split('/').last, overflow: TextOverflow.ellipsis),
            actions: [
              if (f != null)
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: f.content));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  },
                ),
            ],
          ),
          body: err != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Text(
                      err is BrowseError && err.status == 415 ? 'This is a binary file, so it can\'t be shown here.' : '$err',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : f == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.xs),
                        child: Text(
                          '$path · ${sizeLabel(f.size)}${f.truncated ? ' · showing the first ${sizeLabel(f.content.length)}' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(child: _FileBody(content: f.content, line: line)),
                    ]),
        );
      },
    );
  }
}

const _bodyStyle = TextStyle(fontFamily: AppTheme.monoFontFamily, fontSize: 12.5, height: 1.4);

class _FileBody extends StatefulWidget {
  const _FileBody({required this.content, this.line});
  final String content;
  final int? line;

  @override
  State<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends State<_FileBody> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final line = widget.line;
    if (line != null && line > 1) {
      // Monospace with a fixed line height: line N starts at (N-1) * lineHeight. Keep two lines of context above.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final y = (line - 3).clamp(0, 1 << 30) * _bodyStyle.fontSize! * _bodyStyle.height!;
        _scroll.jumpTo(y.clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final lines = widget.content.split('\n');
    final hit = line != null && line >= 1 && line <= lines.length;
    final Widget text = hit
        ? SelectableText.rich(TextSpan(style: _bodyStyle, children: [
            TextSpan(text: lines.take(line - 1).map((l) => '$l\n').join()),
            TextSpan(text: lines[line - 1], style: TextStyle(backgroundColor: Theme.of(context).colorScheme.tertiaryContainer)),
            TextSpan(text: line < lines.length ? '\n${lines.skip(line).join('\n')}' : ''),
          ]))
        : SelectableText(widget.content, style: _bodyStyle);
    return SingleChildScrollView(
      controller: _scroll,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(Spacing.md),
        child: text,
      ),
    );
  }
}
