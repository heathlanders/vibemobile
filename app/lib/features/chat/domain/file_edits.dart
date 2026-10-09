// Session file viewer models (proposal 20, session-rest.md). Server-built
// views over the session's persisted Edit/Write tool calls — the client never
// diffs; it renders the prefixed diff text the daemon returns.

/// One row in the changed-files list (git-status analog).
class ChangedFile {
  ChangedFile({
    required this.path,
    required this.relPath,
    required this.edits,
    required this.adds,
    required this.dels,
    required this.written,
    required this.lastTs,
  });

  final String path;
  final String relPath;
  final int edits;
  final int adds;
  final int dels;

  /// A `Write` created/overwrote the file — prior content unknown, so its diff
  /// renders as all-additions.
  final bool written;
  final String lastTs;

  factory ChangedFile.fromJson(Map<String, dynamic> j) => ChangedFile(
        path: j['path'] as String,
        relPath: j['relPath'] as String? ?? j['path'] as String,
        edits: j['edits'] as int? ?? 0,
        adds: j['adds'] as int? ?? 0,
        dels: j['dels'] as int? ?? 0,
        written: j['written'] as bool? ?? false,
        lastTs: j['lastTs'] as String? ?? '',
      );
}

/// One edit section within a file's diff (edits are not chained server-side).
class FileEditEntry {
  FileEditEntry({
    required this.ts,
    required this.tool,
    required this.replaceAll,
    required this.diff,
    required this.adds,
    required this.dels,
    required this.truncated,
  });

  final String ts;
  final String tool; // Edit | Write
  final bool replaceAll;

  /// Unified-diff text with `+`/`-`/`@@` line prefixes; cuts carry a visible
  /// `… +N lines truncated` marker (never silent).
  final String diff;
  final int adds;
  final int dels;
  final bool truncated;

  factory FileEditEntry.fromJson(Map<String, dynamic> j) => FileEditEntry(
        ts: j['ts'] as String? ?? '',
        tool: j['tool'] as String? ?? 'Edit',
        replaceAll: j['replaceAll'] as bool? ?? false,
        diff: j['diff'] as String? ?? '',
        adds: j['adds'] as int? ?? 0,
        dels: j['dels'] as int? ?? 0,
        truncated: j['truncated'] as bool? ?? false,
      );
}

/// All edit sections for one file, ts order.
class FileDiff {
  FileDiff({required this.path, required this.relPath, required this.edits});

  final String path;
  final String relPath;
  final List<FileEditEntry> edits;

  factory FileDiff.fromJson(Map<String, dynamic> j) => FileDiff(
        path: j['path'] as String,
        relPath: j['relPath'] as String? ?? j['path'] as String,
        edits: ((j['edits'] as List?) ?? const [])
            .map((e) => FileEditEntry.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// Current on-disk content of an edited file (the full-file toggle).
class FileContent {
  FileContent({required this.path, required this.relPath, required this.content, required this.size, required this.truncated});

  final String path;
  final String relPath;
  final String content;
  final int size;
  final bool truncated;

  factory FileContent.fromJson(Map<String, dynamic> j) => FileContent(
        path: j['path'] as String,
        relPath: j['relPath'] as String? ?? j['path'] as String,
        content: j['content'] as String? ?? '',
        size: j['size'] as int? ?? 0,
        truncated: j['truncated'] as bool? ?? false,
      );
}
