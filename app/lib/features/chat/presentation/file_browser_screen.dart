import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/platform.dart';
import '../../../core/providers.dart';
import '../../../core/spacing.dart';
import '../../../core/token_store.dart';
import '../../../core/widgets.dart';
import '../../sessions/domain/session.dart';
import '../../editor/presentation/code_editor_screen.dart';
import '../../editor/presentation/editor_opener.dart';
import '../../files/data/project_files_api.dart';
import '../../files/presentation/file_download.dart';
import '../data/browse_api.dart';

/// Browser for a project's (or a chat's) files (proposals 46, 59): folders and text files to read,
/// plus download and upload. Back goes up a folder before it leaves the screen.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key, required this.api, required this.title, this.pickFiles, this.onOpenFile});
  final ProjectFilesApi api;
  final String title;

  /// Replaces opening a file in a pushed editor (the desktop workspace opens a tab instead).
  final void Function(ProjectFilesApi api, String path)? onOpenFile;

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
    final open = widget.onOpenFile;
    if (open != null) return open(_api, _join(e.name));
    await Navigator.of(context).push(sharedAxisRoute(CodeEditorScreen(api: _api, path: _join(e.name))));
  }

  void _progressTo(int done, int total) {
    if (mounted) setState(() => _progress = total > 0 ? done / total : null);
  }

  Future<void> _download(BrowseEntry e) => downloadProjectFile(
        context,
        _api,
        _join(e.name),
        onStart: (name) => setState(() {
          _status = 'Downloading $name…';
          _progress = null;
        }),
        onProgress: _progressTo,
        onEnd: () {
          if (mounted) setState(() => _status = null);
        },
      );

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

/// Pushes the file browser for a project's folder. [onOpenFile] overrides where a tapped file opens.
Future<void> openProjectFiles(BuildContext context, Creds creds, Project project, {void Function(ProjectFilesApi api, String path)? onOpenFile}) =>
    Navigator.of(context).push(
      sharedAxisRoute(FileBrowserScreen(api: ProjectFilesApi.project(dioFor(creds), project.id), title: project.label, onOpenFile: onOpenFile)),
    );

/// Opens a file named in chat (proposal 48) in the code editor, at [line]. The only requests it can
/// make are the session's `files/text` routes (the daemon confines, hides secrets, refuses binaries);
/// the editor shows refusals itself. Nothing is launched outside the app. [api] is for tests.
Future<void> openChatFile(
  BuildContext context, {
  required String sessionId,
  required String path,
  int? line,
  Creds? creds,
  ProjectFilesApi? api,
}) async {
  final files = api ?? ProjectFilesApi.session(dioFor(creds!), sessionId);
  final tab = EditorOpener.maybeOf(context);
  if (tab != null) return tab(files, path, line: line);
  await Navigator.of(context).push(sharedAxisRoute(CodeEditorScreen(api: files, path: path, line: line)));
}
