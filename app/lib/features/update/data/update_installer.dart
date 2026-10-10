import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/app_log.dart';
import '../domain/update_info.dart';
import 'update_api.dart';

/// Platform-specific install steps. Thin IO around the pure helpers in
/// `update_info.dart`.
class UpdateInstaller {
  UpdateInstaller(this._api);
  final UpdateApi _api;

  /// Windows: the exe's dir if we can write to it (else null → manual update).
  static String? writableWindowsInstallDir() {
    final dir = windowsInstallDir(Platform.resolvedExecutable);
    if (dir == null) return null;
    try {
      final probe = File('$dir${Platform.pathSeparator}.vibe_write_test_$pid');
      probe.writeAsStringSync('x');
      probe.deleteSync();
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<void> installAndroid(String serverBaseUrl, ReleaseFile f, void Function(double) onProgress) async {
    final dir = await Directory((await getTemporaryDirectory()).path).createTemp('update_');
    final apk = File('${dir.path}${Platform.pathSeparator}update.apk');
    await _api.download(downloadUrl(serverBaseUrl, f.file), apk, f.sha256, onProgress);
    final r = await OpenFilex.open(apk.path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) throw Exception('installer: ${r.message}');
  }

  /// Download, verify, extract, then hand off to a detached PowerShell and exit.
  Future<void> installWindows(
    String serverBaseUrl,
    ReleaseFile f,
    String installDir,
    void Function(double) onProgress,
  ) async {
    final sep = Platform.pathSeparator;
    final tmp = await Directory.systemTemp.createTemp('vibemobile_update_');
    final zip = File('${tmp.path}${sep}update.zip');
    await _api.download(downloadUrl(serverBaseUrl, f.file), zip, f.sha256, onProgress);

    final out = Directory('${tmp.path}${sep}extracted')..createSync();
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    for (final e in archive) {
      final segs = safeEntrySegments(e.name);
      if (segs == null) throw Exception('unsafe path in archive: ${e.name}');
      final path = [out.path, ...segs].join(sep);
      if (e.isFile) {
        final file = File(path)..createSync(recursive: true);
        file.writeAsBytesSync(e.content);
      } else {
        Directory(path).createSync(recursive: true);
      }
    }

    final exeName = Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;
    if (!File('${out.path}$sep$exeName').existsSync()) throw Exception('archive has no $exeName');
    final script = File('${tmp.path}${sep}update.ps1')
      ..writeAsStringSync(buildUpdateScript(
        pid: pid,
        extractedDir: out.path,
        installDir: installDir,
        exeName: exeName,
        logPath: '${tmp.path}${sep}update.log',
      ));
    await Process.start(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path],
      mode: ProcessStartMode.detached,
    );
    AppLog.info('update: handed off to ${script.path}');
    exit(0);
  }
}
