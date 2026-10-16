import 'dart:convert';
import 'dart:io';

import '../../workspace/domain/work_tab.dart';
import 'editor_ipc.dart';

/// A file open in the editor window.
class EditorTabRef {
  const EditorTabRef(this.scope, this.path);
  final String scope, path;

  String get id => fileTabId(scope, path);
  String get name => path.split('/').last;

  @override
  bool operator ==(Object other) => other is EditorTabRef && other.scope == scope && other.path == path;

  @override
  int get hashCode => Object.hash(scope, path);
}

enum EditorOpenOutcome { opened, focused, evictedOldest, full }

/// The editor window's tab list (proposal 62): at most [max] tabs, newest last. Pure, so the
/// rules are unit-testable; [isDirty] says which tabs hold unsaved edits.
class EditorTabs {
  EditorTabs({this.max = 8, required this.isDirty});
  static const maxTabs = 8;

  final int max;
  final bool Function(EditorTabRef) isDirty;
  final List<EditorTabRef> tabs = [];
  EditorTabRef? active;

  /// Opens [t], or focuses it when already open. At the cap the oldest clean tab is closed to
  /// make room; with every tab dirty nothing changes and the result is [EditorOpenOutcome.full].
  EditorOpenOutcome open(EditorTabRef t) {
    if (tabs.contains(t)) {
      active = t;
      return EditorOpenOutcome.focused;
    }
    var outcome = EditorOpenOutcome.opened;
    if (tabs.length >= max) {
      final victim = tabs.where((x) => !isDirty(x)).firstOrNull;
      if (victim == null) return EditorOpenOutcome.full;
      tabs.remove(victim);
      outcome = EditorOpenOutcome.evictedOldest;
    }
    tabs.add(t);
    active = t;
    return outcome;
  }

  /// Removes [t]; the neighbour at its position becomes active when it was.
  void close(EditorTabRef t) {
    final i = tabs.indexOf(t);
    if (i < 0) return;
    tabs.removeAt(i);
    if (active == t) active = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)];
  }

  /// Ctrl+Tab (+1) / Ctrl+Shift+Tab (-1), wrapping.
  void cycle(int delta) {
    if (tabs.isEmpty) return;
    final i = active == null ? 0 : tabs.indexOf(active!);
    active = tabs[(i + delta) % tabs.length];
  }

  Map<String, Object?> toJson() => {
        'tabs': [for (final t in tabs) {'scope': t.scope, 'path': t.path}],
        'active': active == null ? null : {'scope': active!.scope, 'path': active!.path},
      };

  /// Rebuilds from [toJson] output; entries that fail the request validation are skipped.
  void restore(Object? json) {
    if (json is! Map) return;
    EditorTabRef? ref(Object? e) {
      if (e is! Map) return null;
      final r = EditorRequest.parse(jsonEncode({'v': 1, 'scope': e['scope'], 'path': e['path']}));
      return r == null ? null : EditorTabRef(r.scope!, r.path!);
    }

    final list = json['tabs'];
    if (list is! List) return;
    for (final e in list) {
      final t = ref(e);
      if (t != null && !tabs.contains(t) && tabs.length < max) tabs.add(t);
    }
    final a = ref(json['active']);
    active = a != null && tabs.contains(a) ? a : tabs.firstOrNull;
  }

  /// Reads [file] (missing or corrupt → no tabs).
  void load(File file) {
    try {
      restore(jsonDecode(file.readAsStringSync()));
    } catch (_) {}
  }

  void save(File file) {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(toJson()));
    } catch (_) {}
  }
}
