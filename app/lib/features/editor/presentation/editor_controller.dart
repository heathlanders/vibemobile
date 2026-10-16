import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/data/browse_api.dart';
import '../../files/data/project_files_api.dart';
import '../domain/editor_doc.dart';
import '../domain/editor_language.dart';

/// Which file an editor shows. Equality is scope + path (+ read-only), so the same file opened twice
/// shares one [EditorDoc]; the [api] and [line] ride along.
class EditorTarget {
  const EditorTarget(this.api, this.path, {this.line, this.readOnly = false});
  final ProjectFilesApi api;
  final String path;

  /// 1-based line to jump to on open.
  final int? line;
  final bool readOnly;

  @override
  bool operator ==(Object other) => other is EditorTarget && other.api.scope == api.scope && other.path == path && other.readOnly == readOnly;

  @override
  int get hashCode => Object.hash(api.scope, path, readOnly);
}

final editorDocProvider = NotifierProvider.autoDispose.family<EditorDocNotifier, EditorDoc, EditorTarget>(EditorDocNotifier.new);

class EditorDocNotifier extends Notifier<EditorDoc> {
  EditorDocNotifier(this.target);
  final EditorTarget target;

  @override
  EditorDoc build() {
    Future.microtask(load);
    return EditorDoc(language: languageFor(target.path), readOnly: target.readOnly);
  }

  /// (Re)reads the file from the daemon, discarding any unsaved buffer.
  Future<void> load() async {
    try {
      final d = await target.api.readDoc(target.path);
      if (!ref.mounted) return;
      state = state.copyWith(
        status: EditorStatus.ready,
        content: d.content,
        baseSha: d.sha,
        mtime: d.mtime,
        size: d.size,
        dirty: false,
        gen: state.gen + 1,
      );
    } on BrowseError catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        status: EditorStatus.failed,
        failure: switch (e.status) {
          413 => EditorFailure.tooLarge,
          403 => EditorFailure.forbidden,
          415 => EditorFailure.binary,
          _ => EditorFailure.other,
        },
        error: e.message,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = state.copyWith(status: EditorStatus.failed, failure: EditorFailure.other, error: 'Could not open the file');
    }
  }

  void setDirty(bool dirty) {
    if (state.dirty != dirty) state = state.copyWith(dirty: dirty);
  }

  /// Saves [text]. [baseSha] defaults to the hash it was read at; Overwrite passes the 409's.
  Future<SaveOutcome> save(String text, {String? baseSha}) async {
    if (state.saving) return const SaveFailed('Already saving');
    state = state.copyWith(saving: true);
    try {
      final r = await target.api.saveText(target.path, text, baseSha: baseSha ?? state.baseSha);
      if (!ref.mounted) return const Saved();
      state = state.copyWith(saving: false, content: text, baseSha: r.sha, mtime: r.mtime, size: r.size, dirty: false);
      return const Saved();
    } on StaleFileError catch (e) {
      if (!ref.mounted) return SaveConflict(e.sha);
      state = state.copyWith(saving: false);
      return SaveConflict(e.sha);
    } on BrowseError catch (e) {
      if (ref.mounted) state = state.copyWith(saving: false);
      return SaveFailed(e.message);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(saving: false);
      return const SaveFailed('Could not save the file');
    }
  }
}
