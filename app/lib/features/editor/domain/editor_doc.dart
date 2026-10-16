/// Why a file could not be opened in the editor.
enum EditorFailure {
  /// 413: over the daemon's edit cap. Download it instead.
  tooLarge,

  /// 403: a secret, `.git`, or outside the project.
  forbidden,

  /// 415: binary or not valid UTF-8. Download it instead.
  binary,

  /// Anything else (404, network, ...).
  other,
}

enum EditorStatus { loading, ready, failed }

/// One open file (proposal 60). [content] is the text as last read or saved; the live buffer is the
/// editor controller's, which reports only [dirty] back here. [gen] changes on every (re)load so the
/// editor view rebuilds its buffer from [content].
class EditorDoc {
  const EditorDoc({
    this.status = EditorStatus.loading,
    this.content = '',
    this.baseSha = '',
    this.mtime,
    this.size = 0,
    this.dirty = false,
    this.language = 'plaintext',
    this.readOnly = false,
    this.saving = false,
    this.failure,
    this.error,
    this.gen = 0,
  });

  final EditorStatus status;
  final String content;

  /// The hash the next save quotes; the daemon refuses it if the file changed since.
  final String baseSha;
  final String? mtime;
  final int size;
  final bool dirty;
  final String language;
  final bool readOnly;
  final bool saving;
  final EditorFailure? failure;
  final String? error;
  final int gen;

  EditorDoc copyWith({
    EditorStatus? status,
    String? content,
    String? baseSha,
    String? mtime,
    int? size,
    bool? dirty,
    bool? saving,
    EditorFailure? failure,
    String? error,
    int? gen,
  }) =>
      EditorDoc(
        status: status ?? this.status,
        content: content ?? this.content,
        baseSha: baseSha ?? this.baseSha,
        mtime: mtime ?? this.mtime,
        size: size ?? this.size,
        dirty: dirty ?? this.dirty,
        language: language,
        readOnly: readOnly,
        saving: saving ?? this.saving,
        failure: failure,
        error: error,
        gen: gen ?? this.gen,
      );
}

/// What a save attempt came to.
sealed class SaveOutcome {
  const SaveOutcome();
}

class Saved extends SaveOutcome {
  const Saved();
}

/// The file changed on the server since it was read; [sha] is its current hash.
class SaveConflict extends SaveOutcome {
  const SaveConflict(this.sha);
  final String? sha;
}

class SaveFailed extends SaveOutcome {
  const SaveFailed(this.message);
  final String message;
}
