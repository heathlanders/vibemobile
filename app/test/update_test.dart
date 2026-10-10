import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/update/domain/update_info.dart';

const _json = {
  'version': '1.0.18',
  'build': 19,
  'notes': ' fixes ',
  'apk': {'file': 'vibemobile-1.0.18.apk', 'sha256': 'ABC'},
  'windows': null,
};

void main() {
  test('parses latest.json', () {
    final i = UpdateInfo.parse(_json)!;
    expect(i.version, '1.0.18');
    expect(i.build, 19);
    expect(i.notes, 'fixes');
    expect(i.apk!.file, 'vibemobile-1.0.18.apk');
    expect(i.apk!.sha256, 'abc');
    expect(i.windows, isNull);
  });

  test('malformed documents parse to null', () {
    expect(UpdateInfo.parse('x'), isNull);
    expect(UpdateInfo.parse({'version': '1', 'build': '2'}), isNull);
    expect(UpdateInfo.parse({'version': '1', 'build': 2, 'apk': {'file': 'a'}})!.apk, isNull);
  });

  test('availability needs a newer build and a platform entry', () {
    final i = UpdateInfo.parse(_json)!;
    expect(i.isAvailable(18, 'android'), isTrue);
    expect(i.isAvailable(19, 'android'), isFalse);
    expect(i.isAvailable(18, 'windows'), isFalse);
    expect(i.isAvailable(18, 'linux'), isFalse);
  });

  test('urls use the host on 443 under /dl/', () {
    expect(latestJsonUrl('https://box.tailnet.ts.net:8443').toString(), 'https://box.tailnet.ts.net/dl/latest.json');
    expect(downloadUrl('https://box.tailnet.ts.net/x', 'a.apk').toString(), 'https://box.tailnet.ts.net/dl/a.apk');
  });

  test('psQuote doubles single quotes', () {
    expect(psQuote("C:\\it's"), "'C:\\it''s'");
  });

  test('windowsInstallDir refuses drive roots', () {
    expect(windowsInstallDir(r'C:\Users\u\AppData\Local\VibeMobile\vibemobile.exe'), r'C:\Users\u\AppData\Local\VibeMobile');
    expect(windowsInstallDir(r'C:\App\vibemobile.exe'), r'C:\App');
    expect(windowsInstallDir(r'C:\vibemobile.exe'), isNull);
    expect(windowsInstallDir('vibemobile.exe'), isNull);
    expect(windowsInstallDir(r'C:\a\..\vibemobile.exe'), isNull);
  });

  test('safeEntrySegments rejects traversal and absolute paths', () {
    expect(safeEntrySegments('data/flutter_assets/a.bin'), ['data', 'flutter_assets', 'a.bin']);
    expect(safeEntrySegments('../evil'), isNull);
    expect(safeEntrySegments(r'a\..\evil'), isNull);
    expect(safeEntrySegments('/etc/passwd'), isNull);
    expect(safeEntrySegments(r'C:\x'), isNull);
  });

  test('update script waits, mirrors, relaunches with quoted paths', () {
    final s = buildUpdateScript(
      pid: 42,
      extractedDir: r"C:\Temp\it's\extracted",
      installDir: r'C:\Apps\VibeMobile',
      exeName: 'vibemobile.exe',
      logPath: r'C:\Temp\update.log',
    );
    expect(s, startsWith(r"Start-Transcript -Path 'C:\Temp\update.log' -Force"));
    expect(s, contains('Wait-Process -Id 42 -ErrorAction SilentlyContinue'));
    expect(s, contains(r"$exe = 'C:\Apps\VibeMobile\vibemobile.exe'"));
    expect(s, contains(r"Get-Process -Name 'vibemobile'"));
    expect(s, contains(r'Others | Stop-Process -Force'));
    expect(s, contains(r"robocopy 'C:\Temp\it''s\extracted' 'C:\Apps\VibeMobile' /MIR /R:10 /W:1 /NFL /NDL /NJH /NJS"));
    // Relaunch comes before the failure exit, so a failed copy still reopens the app.
    expect(s.indexOf(r'Start-Process -FilePath $exe'), lessThan(s.indexOf(r'if ($code -gt 7)')));
  });
}
