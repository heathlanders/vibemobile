import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/domain/session.dart';
import '../../files/data/project_files_api.dart';
import '../data/browse_api.dart';

/// Browser for a project's (or a chat's) files (proposals 46, 59): folders and text files to read,
/// plus download and upload. Back goes up a folder before it leaves the screen.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, required this.api, required this.title, this.pickFiles});
  final ProjectFilesApi api;
  final String title;

  /// Tests inject the picker; production uses the system file picker.
  final Future<List<UploadSource>> Function()? pickFiles;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

Future<List<UploadSource>> _systemPick() async {
  final picked = await FilePicker.pickFiles();
  return [for (final f in picked) UploadSource(name: f.name, length: await f.length() ?? 0, open: f.readAsByteStream)];
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  ProjectFilesApi get _api => widget.api;
  String _path = '';
  BrowseListing? _listing;
  String? _error;
  bool _loading = true;
  bool _dragging = false;

  /// What the one running transfer is doing ("Uploading a.txt…") and how far along (null = unknown).
  String? _status;
  double? _progress;
  bool get _busy => _status != null;

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
      final l = await _api.list(path);
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

  void _say(String m, {SnackBarAction? action}) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), action: action));
  }

  Future<void> _open(BrowseEntry e) async {
    if (e.isDir) return _go(_join(e.name));
    if (!e.readable) {
      final why = e.type == 'link' ? 'This link points outside the project, so it isn\'t shown.' : 'This looks like a secret (keys, credentials, .env), so it isn\'t shown.';
      _say(why);
      return;
    }
    await Navigator.of(context).push(sharedAxisRoute(FileViewerScreen(path: _join(e.name), load: () => _api.readText(_join(e.name)))));
  }

  void _progressTo(int done, int total) {
    if (mounted) setState(() => _progress = total > 0 ? done / total : null);
  }

  Future<void> _download(BrowseEntry e) async {
    final path = _join(e.name);
    File dest;
    if (isMobile) {
      final dir = Directory('${(await getTemporaryDirectory()).path}/downloads');
      dir.createSync(recursive: true);
      dest = File('${dir.path}/${e.name}');
    } else {
      // The dialog asks about overwriting; saveFile writes an empty file there, which the download replaces.
      final uri = await FilePicker.saveFile(fileName: e.name, bytes: Uint8List(0));
      if (uri == null) return;
      dest = File(uri.toFilePath());
    }
    setState(() {
      _status = 'Downloading ${e.name}…';
      _progress = null;
    });
    try {
      await _api.download(path, dest, onProgress: _progressTo);
      if (!mounted) return;
      setState(() => _status = null);
      if (isMobile) {
        await SharePlus.instance.share(ShareParams(files: [XFile(dest.path)]));
        _say('Downloaded ${e.name}', action: SnackBarAction(label: 'Open', onPressed: () => OpenFilex.open(dest.path)));
      } else {
        _say('Saved ${e.name}');
      }
    } on BrowseError catch (err) {
      _say(err.message);
    } catch (_) {
      _say('Could not download ${e.name}');
    } finally {
      if (mounted) setState(() => _status = null);
    }
  }

  Future<void> _pickAndUpload() async {
    final List<UploadSource> picked;
    try {
      picked = await (widget.pickFiles ?? _systemPick)();
    } catch (_) {
      return _say('Could not pick a file');
    }
    await _upload(picked);
  }

  Future<bool> _askOverwrite(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$name already exists. Overwrite?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Overwrite')),
          ],
        ),
      ) ??
      false;

  /// Uploads each source into the folder open now, one at a time; an existing name asks first.
  Future<void> _upload(List<UploadSource> sources) async {
    if (sources.isEmpty || _busy) return;
    final dir = _path;
    var done = 0;
    for (final src in sources) {
      var overwrite = false;
      while (mounted) {
        setState(() {
          _status = 'Uploading ${src.name}…';
          _progress = 0;
        });
        try {
          await _api.upload(dir, src, overwrite: overwrite, onProgress: _progressTo);
          done++;
        } on BrowseError catch (err) {
          if (err.status == 409 && !overwrite) {
            setState(() => _status = null);
            if (await _askOverwrite(src.name)) {
              overwrite = true;
              continue;
            }
          } else {
            _say('${src.name}: ${err.message}');
          }
        } catch (_) {
          _say('Could not upload ${src.name}');
        }
        break;
      }
    }
    if (!mounted) return;
    setState(() => _status = null);
    if (done > 0) _say(done == 1 ? 'Uploaded' : 'Uploaded $done files');
    _go(_path);
  }

  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dragging = false);
    await _upload([
      for (final f in d.files)
        if (FileSystemEntity.isFileSync(f.path)) UploadSource.file(File(f.path), name: f.name),
    ]);
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
          title: Text(_path.isEmpty ? widget.title : _path, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(tooltip: 'Upload here', icon: const Icon(Icons.upload_file_outlined), onPressed: _busy ? null : _pickAndUpload),
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => _go(_path)),
          ],
        ),
        body: _error != null
            ? ErrorBody(message: _error!)
            : l == null
                ? const Center(child: CircularProgressIndicator())
                : DropTarget(
                    enable: !isMobile,
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: _onDrop,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(border: _dragging ? Border.all(color: theme.colorScheme.primary, width: 2) : null),
                      child: Column(children: [
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
                                      trailing: e.type == 'file' && e.readable
                                          ? IconButton(tooltip: 'Download', icon: const Icon(Icons.download_outlined), onPressed: _busy ? null : () => _download(e))
                                          : null,
                                      onTap: () => _open(e),
                                    ),
                                  if (l.truncated)
                                    Padding(padding: const EdgeInsets.all(Spacing.lg), child: Text('Only the first ${l.entries.length} entries are shown.', style: theme.textTheme.bodySmall)),
                                ]),
                        ),
                        if (_status != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, Spacing.md),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_progress == null ? _status! : '$_status ${(_progress! * 100).round()}%', style: theme.textTheme.bodySmall),
                              const SizedBox(height: Spacing.xs),
                              LinearProgressIndicator(value: _progress),
                            ]),
                          ),
                      ]),
                    ),
                  ),
      ),
    );
  }
}

/// Pushes the file browser for a project's folder.
Future<void> openProjectFiles(BuildContext context, Creds creds, Project project) => Navigator.of(context).push(
      sharedAxisRoute(FileBrowserScreen(api: ProjectFilesApi.project(dioFor(creds), project.id), title: project.label)),
    );

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
