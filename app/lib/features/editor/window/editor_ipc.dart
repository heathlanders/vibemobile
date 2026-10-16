import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../../../core/app_log.dart';

final _scopeRe = RegExp(r'^(projects|sessions)/[A-Za-z0-9_-]+$');

/// One message to the editor window (proposal 62): open [path] under [scope] (optionally at
/// [line]), or [quit]. Anything that doesn't validate parses to null; the inbox is a local
/// file drop, so treat it as untrusted input.
class EditorRequest {
  const EditorRequest.open(String this.scope, String this.path, {this.line}) : quit = false;
  const EditorRequest.quit()
      : scope = null,
        path = null,
        line = null,
        quit = true;

  final String? scope;
  final String? path;
  final int? line;
  final bool quit;

  Map<String, Object?> toJson() => quit ? {'v': 1, 'quit': true} : {'v': 1, 'scope': scope, 'path': path, if (line != null) 'line': line};

  static EditorRequest? parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['v'] != 1) return null;
      if (j['quit'] == true) return const EditorRequest.quit();
      final scope = j['scope'], path = j['path'], line = j['line'];
      if (scope is! String || !_scopeRe.hasMatch(scope)) return null;
      if (path is! String || path.isEmpty || path.contains('\u0000')) return null;
      if (line != null && (line is! int || line < 1)) return null;
      return EditorRequest.open(scope, path, line: line as int?);
    } catch (_) {
      return null;
    }
  }
}

/// The file-drop channel between the main window and the editor process. [dir] holds
/// `editor.lock` (held by the editor for its whole life), `inbox/` and `tabs.json`.
class EditorIpc {
  EditorIpc(this.dir);
  final Directory dir;

  /// `<app support>/editor`.
  static Future<EditorIpc> forApp() async => EditorIpc(Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}editor'));

  File get _lockFile => File('${dir.path}${Platform.pathSeparator}editor.lock');
  Directory get _inbox => Directory('${dir.path}${Platform.pathSeparator}inbox');
  File get tabsFile => File('${dir.path}${Platform.pathSeparator}tabs.json');

  RandomAccessFile? _held;

  /// Takes the editor lock for this process's lifetime; false when another editor holds it.
  bool acquireLock() {
    try {
      dir.createSync(recursive: true);
      final f = _lockFile.openSync(mode: FileMode.append);
      try {
        f.lockSync(FileLock.exclusive); // non-blocking: throws when held
      } catch (_) {
        f.closeSync();
        return false;
      }
      _held = f;
      return true;
    } catch (e) {
      AppLog.error('editor lock: $e');
      return false;
    }
  }

  void releaseLock() {
    try {
      _held?.closeSync();
    } catch (_) {}
    _held = null;
  }

  /// True when some process holds the editor lock. Takes and releases it when free.
  bool isEditorRunning() {
    try {
      dir.createSync(recursive: true);
      final f = _lockFile.openSync(mode: FileMode.append);
      try {
        f.lockSync(FileLock.exclusive);
      } catch (_) {
        return true;
      } finally {
        try {
          f.closeSync(); // also drops the lock if we got it
        } catch (_) {}
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Writes the request atomically (tmp file, then rename).
  void send(EditorRequest r) {
    _inbox.createSync(recursive: true);
    final rnd = Random.secure();
    final id = '${DateTime.now().microsecondsSinceEpoch.toString().padLeft(18, '0')}-${List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join()}';
    final base = '${_inbox.path}${Platform.pathSeparator}$id';
    File('$base.json.tmp')
      ..writeAsStringSync(jsonEncode(r.toJson()), flush: true)
      ..renameSync('$base.json');
  }

  /// Handles every pending request in send order, then new ones as they land (directory watch,
  /// with a 1 s poll in case the watcher misses). Each file is deleted once read; invalid ones
  /// are deleted and logged. Cancel the returned handle to stop.
  StreamSubscription<void> watch(FutureOr<void> Function(EditorRequest) onRequest) {
    _inbox.createSync(recursive: true);
    var draining = false;
    Future<void> drain() async {
      if (draining) return;
      draining = true;
      try {
        final files = _inbox.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          String text;
          try {
            text = f.readAsStringSync();
            f.deleteSync();
          } catch (_) {
            continue; // raced with another reader; skip
          }
          final r = EditorRequest.parse(text);
          if (r == null) {
            AppLog.error('editor inbox: dropped invalid request ${f.uri.pathSegments.last}');
            continue;
          }
          try {
            await onRequest(r);
          } catch (e) {
            AppLog.error('editor request failed: $e');
          }
        }
      } catch (e) {
        AppLog.error('editor inbox: $e');
      } finally {
        draining = false;
      }
    }

    final ctl = StreamController<void>();
    StreamSubscription<FileSystemEvent>? ws;
    try {
      ws = _inbox.watch().listen((_) => drain(), onError: (_) {});
    } catch (_) {/* poll covers it */}
    final timer = Timer.periodic(const Duration(seconds: 1), (_) => drain());
    ctl.onCancel = () {
      timer.cancel();
      ws?.cancel();
    };
    drain();
    return ctl.stream.listen(null);
  }
}
