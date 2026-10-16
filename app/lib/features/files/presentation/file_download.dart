import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/platform.dart';
import '../../chat/data/browse_api.dart';
import '../data/project_files_api.dart';

/// Downloads [path] from [api] to the device: a temp file handed to the share sheet on a phone, a
/// "save as" file on desktop (shared by the file browser and the editor's too-large / binary states).
/// [onStart] runs once the destination is chosen, [onEnd] once the transfer has finished or failed.
/// Outcomes and refusals are reported on the surrounding [ScaffoldMessenger].
Future<void> downloadProjectFile(
  BuildContext context,
  ProjectFilesApi api,
  String path, {
  void Function(String name)? onStart,
  void Function(int received, int total)? onProgress,
  VoidCallback? onEnd,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String m, {SnackBarAction? action}) => messenger.showSnackBar(SnackBar(content: Text(m), action: action));
  final name = path.split('/').last;
  File dest;
  if (isMobile) {
    final dir = Directory('${(await getTemporaryDirectory()).path}/downloads');
    dir.createSync(recursive: true);
    dest = File('${dir.path}/$name');
  } else {
    // The dialog asks about overwriting; saveFile writes an empty file there, which the download replaces.
    final uri = await FilePicker.saveFile(fileName: name, bytes: Uint8List(0));
    if (uri == null) return;
    dest = File(uri.toFilePath());
  }
  onStart?.call(name);
  try {
    await api.download(path, dest, onProgress: onProgress);
    onEnd?.call();
    if (isMobile) {
      await SharePlus.instance.share(ShareParams(files: [XFile(dest.path)]));
      say('Downloaded $name', action: SnackBarAction(label: 'Open', onPressed: () => OpenFilex.open(dest.path)));
    } else {
      say('Saved $name');
    }
  } on BrowseError catch (err) {
    onEnd?.call();
    say(err.message);
  } catch (_) {
    onEnd?.call();
    say('Could not download $name');
  }
}
