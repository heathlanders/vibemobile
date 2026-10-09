import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Tiny rolling client error log (build plan 2026-10-06 A1). One file under the
/// app support dir; past [maxBytes] it rotates to `.1` (one generation kept), so
/// the log never exceeds ~2×[maxBytes]. Read back via Settings → Copy logs.
///
/// Never log secrets: callers pass error text, not request headers/tokens.
/// Fail-soft — logging must never throw into the app.
class AppLog {
  AppLog._();

  static const maxBytes = 256 * 1024;
  static File? _file;

  /// Point the log at [dir] (tests) or the platform app support dir.
  static Future<void> init({Directory? dir}) async {
    try {
      final d = dir ?? await getApplicationSupportDirectory();
      _file = File('${d.path}${Platform.pathSeparator}vibemobile.log');
    } catch (_) {/* no writable dir → logging is a no-op */}
  }

  static void error(String msg) => _write('E', msg);
  static void info(String msg) => _write('I', msg);

  static void _write(String level, String msg) {
    final f = _file;
    if (f == null) return;
    try {
      if (f.existsSync() && f.lengthSync() > maxBytes) f.renameSync('${f.path}.1');
      f.writeAsStringSync('${DateTime.now().toIso8601String()} $level $msg\n', mode: FileMode.append, flush: true);
    } catch (_) {/* disk full / locked — drop the line */}
  }

  /// Both generations, oldest first; '' when nothing was logged.
  static Future<String> read() async {
    final f = _file;
    if (f == null) return '';
    final buf = StringBuffer();
    for (final g in [File('${f.path}.1'), f]) {
      try {
        if (await g.exists()) buf.write(await g.readAsString());
      } catch (_) {}
    }
    return buf.toString();
  }
}
