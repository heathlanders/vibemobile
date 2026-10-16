import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/editor/window/editor_ipc.dart';
import 'package:vibemobile/features/editor/window/editor_launcher.dart';
import 'package:vibemobile/features/editor/window/editor_tabs.dart';

void main() {
  group('EditorRequest.parse', () {
    String open(Map<String, Object?> m) => jsonEncode({'v': 1, ...m});

    test('accepts a project / session open, with and without a line', () {
      final a = EditorRequest.parse(open({'scope': 'projects/p-1_x', 'path': 'src/a.dart'}))!;
      expect((a.scope, a.path, a.line, a.quit), ('projects/p-1_x', 'src/a.dart', null, false));
      final b = EditorRequest.parse(open({'scope': 'sessions/abc', 'path': 'a b.txt', 'line': 12}))!;
      expect((b.scope, b.line), ('sessions/abc', 12));
    });

    test('accepts quit', () => expect(EditorRequest.parse(open({'quit': true}))!.quit, isTrue));

    test('rejects bad scope, traversal-looking scope, NUL path, bad line, bad version, junk', () {
      for (final scope in ['projects', 'files/p1', 'projects/', 'projects/a/b', 'projects/../x', 'projects/a b', '../projects/p1', 'projects/p1\n', 7]) {
        expect(EditorRequest.parse(open({'scope': scope, 'path': 'a'})), isNull, reason: '$scope');
      }
      expect(EditorRequest.parse(open({'scope': 'projects/p', 'path': ''})), isNull);
      expect(EditorRequest.parse(open({'scope': 'projects/p', 'path': 'a\u0000b'})), isNull);
      expect(EditorRequest.parse(open({'scope': 'projects/p'})), isNull);
      for (final line in [0, -3, 1.5, '4']) {
        expect(EditorRequest.parse(open({'scope': 'projects/p', 'path': 'a', 'line': line})), isNull, reason: '$line');
      }
      expect(EditorRequest.parse(jsonEncode({'v': 2, 'quit': true})), isNull);
      expect(EditorRequest.parse('not json'), isNull);
      expect(EditorRequest.parse('[]'), isNull);
    });
  });

  group('EditorIpc', () {
    late Directory tmp;
    late EditorIpc ipc;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('editor_ipc_');
      ipc = EditorIpc(Directory('${tmp.path}/editor'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('send then watch delivers in order and deletes the files', () async {
      for (var i = 1; i <= 3; i++) {
        ipc.send(EditorRequest.open('projects/p', 'f$i.txt', line: i));
      }
      ipc.send(const EditorRequest.quit());
      final got = <EditorRequest>[];
      final sub = ipc.watch(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect([for (final r in got) r.quit ? 'quit' : r.path], ['f1.txt', 'f2.txt', 'f3.txt', 'quit']);
      expect(Directory('${tmp.path}/editor/inbox').listSync(), isEmpty);

      // A request that lands while watching is picked up too.
      ipc.send(EditorRequest.open('sessions/s', 'late.txt'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(got.last.path, 'late.txt');
      await sub.cancel();
    });

    test('invalid inbox files are deleted, not delivered or thrown', () async {
      final inbox = Directory('${tmp.path}/editor/inbox')..createSync(recursive: true);
      File('${inbox.path}/000-bad.json').writeAsStringSync('{"v":1,"scope":"../x","path":"a"}');
      File('${inbox.path}/001-junk.json').writeAsStringSync('nope');
      final got = <EditorRequest>[];
      final sub = ipc.watch(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(got, isEmpty);
      expect(inbox.listSync(), isEmpty);
      await sub.cancel();
    });

    test('lock: free when nobody holds it', () {
      expect(ipc.isEditorRunning(), isFalse);
      expect(ipc.isEditorRunning(), isFalse); // probing doesn't leave it held
    });

    // POSIX file locks are per process, so "held" needs a second process.
    test('lock: running while another process holds it, free after it exits', () async {
      final dart = '${Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/flutter'}/bin/dart';
      if (!File(dart).existsSync()) markTestSkipped('no dart binary');
      final script = File('${tmp.path}/hold.dart')..writeAsStringSync('''
import 'dart:io';
void main(List<String> a) {
  Directory(a[0]).createSync(recursive: true);
  File(a[0] + '/editor.lock').openSync(mode: FileMode.append).lockSync(FileLock.exclusive);
  print('ready');
  stdin.readLineSync();
}
''');
      final p = await Process.start(dart, [script.path, ipc.dir.path]);
      final ready = Completer<void>();
      p.stdout.transform(utf8.decoder).listen((s) {
        if (s.contains('ready') && !ready.isCompleted) ready.complete();
      });
      await ready.future.timeout(const Duration(seconds: 60));
      expect(ipc.isEditorRunning(), isTrue);
      expect(ipc.acquireLock(), isFalse);
      p.stdin.writeln();
      await p.exitCode;
      expect(ipc.isEditorRunning(), isFalse);
      expect(ipc.acquireLock(), isTrue);
      ipc.releaseLock();
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('quitEditorWindow returns at once when no editor runs, and sends nothing', () async {
      await quitEditorWindow(ipc: ipc, timeout: const Duration(milliseconds: 200));
      expect(Directory('${tmp.path}/editor/inbox').existsSync(), isFalse);
    });
  });

  group('EditorTabs', () {
    EditorTabRef t(int i) => EditorTabRef('projects/p', 'f$i.txt');
    final dirty = <EditorTabRef>{};
    EditorTabs make() => EditorTabs(isDirty: dirty.contains);
    setUp(dirty.clear);

    test('opening an open file focuses it without duplicating', () {
      final tabs = make();
      tabs.open(t(1));
      tabs.open(t(2));
      expect(tabs.open(t(1)), EditorOpenOutcome.focused);
      expect(tabs.tabs, [t(1), t(2)]);
      expect(tabs.active, t(1));
    });

    test('same path in another scope is a different tab', () {
      final tabs = make()..open(const EditorTabRef('projects/a', 'x'));
      expect(tabs.open(const EditorTabRef('sessions/a', 'x')), EditorOpenOutcome.opened);
      expect(tabs.tabs, hasLength(2));
    });

    test('the 9th tab evicts the oldest clean one', () {
      final tabs = make();
      for (var i = 1; i <= 8; i++) {
        tabs.open(t(i));
      }
      dirty.add(t(1));
      expect(tabs.open(t(9)), EditorOpenOutcome.evictedOldest);
      expect(tabs.tabs, [t(1), t(3), t(4), t(5), t(6), t(7), t(8), t(9)]);
      expect(tabs.active, t(9));
    });

    test('with every tab dirty the 9th is refused and nothing changes', () {
      final tabs = make();
      for (var i = 1; i <= 8; i++) {
        tabs.open(t(i));
        dirty.add(t(i));
      }
      expect(tabs.open(t(9)), EditorOpenOutcome.full);
      expect(tabs.tabs, hasLength(8));
      expect(tabs.active, t(8));
    });

    test('close moves active to the neighbour; cycle wraps both ways', () {
      final tabs = make();
      for (var i = 1; i <= 3; i++) {
        tabs.open(t(i));
      }
      tabs.active = t(2);
      tabs.close(t(2));
      expect(tabs.active, t(3));
      tabs.cycle(1);
      expect(tabs.active, t(1));
      tabs.cycle(-1);
      expect(tabs.active, t(3));
      tabs.close(t(3));
      tabs.close(t(1));
      expect(tabs.active, isNull);
    });
  });

  group('tabs.json', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('editor_tabs_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('round-trips tabs and the active one', () {
      final f = File('${tmp.path}/sub/tabs.json');
      final a = EditorTabs(isDirty: (_) => false)
        ..open(const EditorTabRef('projects/p', 'a.txt'))
        ..open(const EditorTabRef('sessions/s', 'b/c.txt'))
        ..active = const EditorTabRef('projects/p', 'a.txt')
        ..save(f);
      final b = EditorTabs(isDirty: (_) => false)..load(f);
      expect(b.tabs, a.tabs);
      expect(b.active, a.active);
    });

    test('missing, corrupt and hostile files load as empty or skip bad entries', () {
      final f = File('${tmp.path}/tabs.json');
      expect((EditorTabs(isDirty: (_) => false)..load(f)).tabs, isEmpty);
      f.writeAsStringSync('{ not json');
      expect((EditorTabs(isDirty: (_) => false)..load(f)).tabs, isEmpty);
      f.writeAsStringSync(jsonEncode({
        'tabs': [
          {'scope': '../x', 'path': 'a'},
          {'scope': 'projects/p', 'path': 'ok.txt'},
          {'scope': 'projects/p', 'path': 'ok.txt'},
          'junk',
        ],
        'active': {'scope': 'projects/p', 'path': 'gone.txt'},
      }));
      final t = EditorTabs(isDirty: (_) => false)..load(f);
      expect(t.tabs, [const EditorTabRef('projects/p', 'ok.txt')]);
      expect(t.active, const EditorTabRef('projects/p', 'ok.txt'));
    });
  });
}
