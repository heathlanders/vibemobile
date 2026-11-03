import 'package:flutter/material.dart';

import '../../chat/data/browse_api.dart';
import '../data/project_files_api.dart';

/// Uploads [sources] into the root of [api]'s tree one at a time; an existing name asks before
/// overwriting. Failures are shown as snackbars. Returns the names that landed.
Future<List<String>> uploadToRoot(BuildContext context, ProjectFilesApi api, List<UploadSource> sources) async {
  final messenger = ScaffoldMessenger.of(context);
  final done = <String>[];
  for (final src in sources) {
    var overwrite = false;
    while (context.mounted) {
      try {
        await api.upload('', src, overwrite: overwrite);
        done.add(src.name);
      } on BrowseError catch (err) {
        if (err.status == 409 && !overwrite && context.mounted && await _askOverwrite(context, src.name)) {
          overwrite = true;
          continue;
        }
        if (err.status != 409) messenger.showSnackBar(SnackBar(content: Text('${src.name}: ${err.message}')));
      } catch (_) {
        messenger.showSnackBar(SnackBar(content: Text('Could not upload ${src.name}')));
      }
      break;
    }
  }
  if (done.isNotEmpty) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(done.length == 1 ? 'Uploaded ${done.single} to project root' : 'Uploaded ${done.length} files to project root'),
      ),
    );
  }
  return done;
}

Future<bool> _askOverwrite(BuildContext context, String name) async =>
    (await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$name already exists. Overwrite?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Overwrite')),
        ],
      ),
    ) ??
    false);
