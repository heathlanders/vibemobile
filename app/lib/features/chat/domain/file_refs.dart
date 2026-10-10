// File references in chat text (proposal 48): `docs/foo.md`, `src/x.ts:42`, `[plan](./PLAN.md)`.
// Pure detection only. Chat text is untrusted data: a FileRef is just a string pair, and the only
// thing the UI ever does with one is ask the daemon's read-only browse/file for the current session.

import 'link_spans.dart';

class FileRef {
  const FileRef(this.path, [this.line]);
  final String path;
  final int? line;

  @override
  bool operator ==(Object other) => other is FileRef && other.path == path && other.line == line;
  @override
  int get hashCode => Object.hash(path, line);
  @override
  String toString() => 'FileRef($path${line != null ? ':$line' : ''})';
}

/// Extensions that make a bare name look like a file. Domain TLDs (com, org, net, io, dev, ...)
/// are deliberately absent so `example.com` is not a file.
const _exts = {
  'md', 'mdx', 'dart', 'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'json', 'yaml', 'yml', 'py', 'sh', 'kt', 'kts',
  'java', 'swift', 'go', 'rs', 'toml', 'txt', 'html', 'css', 'scss', 'sql', 'gradle', 'xml', 'lock', 'example',
  'cpp', 'hpp', 'rb', 'php', 'ini', 'cfg', 'conf', 'log', 'properties', 'plist', 'csv', 'gitignore',
};
const _specialNames = {'Dockerfile', 'Makefile'};
const _rootNames = {'README.md', 'PLAN.md', 'CLAUDE.md', 'package.json', 'pubspec.yaml'};

const _pathChars = r'[A-Za-z0-9_.@+\-]';
final _codeRe = RegExp('^(/?$_pathChars+(?:/$_pathChars+)*/?)(?::(\\d+)(?::(\\d+))?)?\$');
final _tokenRe = RegExp('(?<![A-Za-z0-9_/.:@~+\\-])(/?$_pathChars+(?:/$_pathChars+)*)(?::(\\d+)(?::(\\d+))?)?');
final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

bool _hasKnownName(String segment) {
  if (_specialNames.contains(segment)) return true;
  final dot = segment.lastIndexOf('.');
  if (dot < 0 || dot == segment.length - 1) return false;
  return _exts.contains(segment.substring(dot + 1).toLowerCase());
}

bool _safePath(String p) {
  if (p.isEmpty || p.contains('//') || p.toLowerCase().startsWith('www.')) return false;
  final segs = p.split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return false;
  // `.` alone or `..`/`...` anywhere: not a file in the project.
  return segs.every((s) => s == '.' ? segs.length > 1 : s.replaceAll('.', '').isNotEmpty);
}

FileRef? _make(String path, String? line) {
  if (!_safePath(path)) return null;
  final n = line == null ? null : int.tryParse(line);
  final clean = path.startsWith('./') ? path.substring(2) : path;
  return clean.isEmpty ? null : FileRef(clean, n != null && n > 0 ? n : null);
}

/// An inline-code run that is, in its entirety, a path: has a `/` or a known extension, optional
/// `:line` / `:line:col`. No spaces. Null otherwise.
FileRef? detectFileRef(String text) {
  final m = _codeRe.firstMatch(text.trim());
  if (m == null) return null;
  final path = m.group(1)!;
  if (path.contains('/')) {
    // `1/2` or `3/4` are not paths: at least one segment needs a letter.
    if (!RegExp(r'[A-Za-z]').hasMatch(path)) return null;
  } else if (!_hasKnownName(path)) {
    return null;
  }
  return _make(path, m.group(2));
}

/// A markdown link target `[t](target)` that is not a URL: any scheme (`javascript:`, `file:`,
/// `mailto:`, `http:`) or `//`/`www.` start is rejected. A leading `./` and any `#anchor` are dropped.
FileRef? fileRefFromLinkTarget(String target) {
  var t = target.trim();
  final hash = t.indexOf('#');
  if (hash >= 0) t = t.substring(0, hash);
  final m = _codeRe.firstMatch(t);
  if (m == null) return null;
  // `a.md:10` looks like a scheme; a real scheme is never followed by only a line number.
  if (_scheme.hasMatch(t) && m.group(2) == null) return null;
  return _make(m.group(1)!, m.group(2));
}

/// Stricter bare-text rule: `/` AND a known extension on the last segment, or a well-known root name.
FileRef? _bareRef(String path, String? line) {
  final slash = path.lastIndexOf('/');
  final last = path.substring(slash + 1);
  final ok = slash >= 0 ? _hasKnownName(last) : _rootNames.contains(path);
  return ok ? _make(path, line) : null;
}

/// A run of plain text: text, or a file reference found in it.
class FileSegment {
  const FileSegment(this.text, [this.ref]);
  final String text;
  final FileRef? ref;

  @override
  bool operator ==(Object other) => other is FileSegment && other.text == text && other.ref == ref;
  @override
  int get hashCode => Object.hash(text, ref);
  @override
  String toString() => 'FileSegment($text${ref != null ? ' ->$ref' : ''})';
}

/// Splits plain paragraph text into text and file-reference segments. [text] is expected to hold
/// no URLs (see [splitFileRefsSkippingUrls]). A trailing `.` is not part of a path.
List<FileSegment> splitFileRefs(String text) {
  final out = <FileSegment>[];
  var last = 0;
  for (final m in _tokenRe.allMatches(text)) {
    var path = m.group(1)!;
    final line = m.group(2);
    var end = m.end;
    if (line == null) {
      final trimmed = path.replaceFirst(RegExp(r'\.+$'), '');
      end -= path.length - trimmed.length;
      path = trimmed;
    }
    if (path.isEmpty) continue;
    final ref = _bareRef(path, line);
    if (ref == null) continue;
    if (m.start > last) out.add(FileSegment(text.substring(last, m.start)));
    out.add(FileSegment(text.substring(m.start, end), ref));
    last = end;
  }
  if (last < text.length) out.add(FileSegment(text.substring(last)));
  return out;
}

/// Like [splitFileRefs] but never looks inside an http(s) URL.
List<FileSegment> splitFileRefsSkippingUrls(String text) => [
      for (final s in splitLinks(text))
        if (s.isLink) FileSegment(s.text) else ...splitFileRefs(s.text),
    ];
