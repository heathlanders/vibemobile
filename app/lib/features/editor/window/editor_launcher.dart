import 'dart:io';

import '../../../core/app_log.dart';
import 'editor_ipc.dart';
import 'editor_native.dart';

DateTime? _lastSpawn;

/// Windows: sends [path] to the editor window, starting it if it isn't running (proposal 62).
/// The new process may not hold the lock yet, so no second spawn within 5 s.
Future<void> openInEditorWindow(String scope, String path, {int? line, EditorIpc? ipc}) async {
  try {
    final ipc0 = ipc ?? await EditorIpc.forApp();
    EditorNative.allowAnyForeground();
    ipc0.send(EditorRequest.open(scope, path, line: line));
    final recent = _lastSpawn != null && DateTime.now().difference(_lastSpawn!) < const Duration(seconds: 5);
    if (!recent && !ipc0.isEditorRunning()) {
      _lastSpawn = DateTime.now();
      await Process.start(Platform.resolvedExecutable, ['--editor'], mode: ProcessStartMode.detached);
    }
  } catch (e) {
    AppLog.error('open in editor window failed: $e');
  }
}

/// The editor window is still open after a quit request.
class EditorStillOpen implements Exception {
  const EditorStillOpen();
  @override
  String toString() => 'Close the editor window to update';
}

/// Asks a running editor window to quit and waits for it to release its lock (it may prompt about
/// unsaved edits first). Throws [EditorStillOpen] when it is still there after [timeout].
Future<void> quitEditorWindow({EditorIpc? ipc, Duration timeout = const Duration(seconds: 15), Duration poll = const Duration(milliseconds: 250)}) async {
  final ipc0 = ipc ?? await EditorIpc.forApp();
  if (!ipc0.isEditorRunning()) return;
  EditorNative.allowAnyForeground();
  ipc0.send(const EditorRequest.quit());
  final end = DateTime.now().add(timeout);
  while (ipc0.isEditorRunning()) {
    if (DateTime.now().isAfter(end)) throw const EditorStillOpen();
    await Future<void>.delayed(poll);
  }
}
