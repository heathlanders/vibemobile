/// One downloadable artifact in `latest.json`.
class ReleaseFile {
  const ReleaseFile(this.file, this.sha256);
  final String file;
  final String sha256;

  static ReleaseFile? parse(Object? j) {
    if (j is! Map) return null;
    final f = j['file'], h = j['sha256'];
    if (f is! String || h is! String || f.isEmpty) return null;
    return ReleaseFile(f, h.toLowerCase());
  }
}

/// `https://<host>/dl/latest.json` written by scripts/release.sh.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.build, this.notes = '', this.apk, this.windows});
  final String version;
  final int build;
  final String notes;
  final ReleaseFile? apk;
  final ReleaseFile? windows;

  /// Null when the document is malformed.
  static UpdateInfo? parse(Object? j) {
    if (j is! Map) return null;
    final v = j['version'], b = j['build'];
    if (v is! String || b is! int) return null;
    final n = j['notes'];
    return UpdateInfo(
      version: v,
      build: b,
      notes: n is String ? n.trim() : '',
      apk: ReleaseFile.parse(j['apk']),
      windows: ReleaseFile.parse(j['windows']),
    );
  }

  /// The artifact for [platform] ('android' | 'windows'); null when none (feature off).
  ReleaseFile? entryFor(String platform) => switch (platform) {
        'android' => apk,
        'windows' => windows,
        _ => null,
      };

  /// Newer build than [currentBuild] AND an artifact exists for [platform].
  bool isAvailable(int currentBuild, String platform) => build > currentBuild && entryFor(platform) != null;
}

/// Always `https://<host>/dl/<name>` on 443, whatever port the daemon URL uses.
Uri downloadUrl(String serverBaseUrl, String name) {
  final host = Uri.parse(serverBaseUrl).host;
  return Uri(scheme: 'https', host: host, path: '/dl/$name');
}

Uri latestJsonUrl(String serverBaseUrl) => downloadUrl(serverBaseUrl, 'latest.json');

/// Single-quoted PowerShell literal ('' escapes a quote).
String psQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// The install dir (parent of [exePath]) if it is safe to /MIR into, else null:
/// needs at least two path components (refuses a drive root like `C:\`) and the
/// exe must sit directly in it. Accepts `\` or `/` separators.
String? windowsInstallDir(String exePath) {
  final parts = exePath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  if (parts.length < 3 || parts.contains('..')) return null; // drive + dir + exe
  final sep = exePath.contains('\\') ? '\\' : '/';
  final i = exePath.lastIndexOf(sep);
  return i <= 0 ? null : exePath.substring(0, i);
}

/// Zip entry name → safe relative segments, or null (absolute / traversal).
List<String>? safeEntrySegments(String name) {
  final segs = name.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty && s != '.').toList();
  if (segs.isEmpty || segs.any((s) => s == '..' || s.contains(':'))) return null;
  if (name.startsWith('/') || name.startsWith('\\')) return null;
  return segs;
}

/// PowerShell that waits for [pid] (and any other copy of the app running from
/// [installDir]), mirrors [extractedDir] over [installDir] (robocopy exit codes
/// 0-7 are success), then relaunches the app. Everything
/// it does is transcribed to [logPath], since it runs hidden.
String buildUpdateScript({
  required int pid,
  required String extractedDir,
  required String installDir,
  required String exeName,
  required String logPath,
}) {
  final exe = '${installDir.replaceAll(RegExp(r'[\\/]+$'), '')}\\$exeName';
  final name = exeName.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
  return [
    'Start-Transcript -Path ${psQuote(logPath)} -Force | Out-Null',
    'Wait-Process -Id $pid -ErrorAction SilentlyContinue',
    // Any other running copy of the app keeps its DLLs locked (robocopy
    // ERROR 32): give it 20 s to exit, then close it.
    '\$exe = ${psQuote(exe)}',
    "function Others { Get-Process -Name ${psQuote(name)} -ErrorAction SilentlyContinue | Where-Object { \$_.Path -eq \$exe } }",
    r'$deadline = (Get-Date).AddSeconds(20)',
    r'while ((Others) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }',
    r'Others | Stop-Process -Force -ErrorAction SilentlyContinue',
    r'Start-Sleep -Seconds 1',
    // Bounded retries: the default is a million, 30 s apart.
    'robocopy ${psQuote(extractedDir)} ${psQuote(installDir)} /MIR /R:10 /W:1 /NFL /NDL /NJH /NJS',
    r'$code = $LASTEXITCODE',
    // Relaunch even if the copy failed, so the app never just disappears.
    r'Start-Process -FilePath $exe',
    r'Stop-Transcript',
    r'if ($code -gt 7) { exit $code }',
    '',
  ].join('\r\n');
}

/// Batch file that starts update.ps1 (in the same dir) in its own minimised
/// console. The app launches this through cmd.exe: a console-less PowerShell
/// started straight from the app never ran the update on a real PC.
String buildUpdateLauncher() => [
      '@echo off',
      r'start "VibeMobile update" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" '
          r'-NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1"',
      '',
    ].join('\r\n');
