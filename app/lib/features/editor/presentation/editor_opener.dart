import 'package:flutter/widgets.dart';

import '../../files/data/project_files_api.dart';

typedef OpenEditorFile = void Function(ProjectFilesApi api, String path, {int? line});

/// Provided by the desktop workspace so a file link or "Browse files…" inside a chat opens a tab
/// there; without one (phone) callers push the editor as a route.
class EditorOpener extends InheritedWidget {
  const EditorOpener({super.key, required this.open, required super.child});
  final OpenEditorFile open;

  static OpenEditorFile? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<EditorOpener>()?.open;

  @override
  bool updateShouldNotify(EditorOpener old) => false;
}
