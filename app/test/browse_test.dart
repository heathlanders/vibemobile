import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vibemobile/features/chat/data/browse_api.dart';
import 'package:vibemobile/features/chat/presentation/file_browser_screen.dart';
import 'package:vibemobile/features/files/data/project_files_api.dart';

Map<String, dynamic> entry(String name, String type, {int? size, bool readable = true}) => {'name': name, 'type': type, 'size': ?size, 'readable': readable};

class FakeApi extends ProjectFilesApi {
  FakeApi(this.tree) : super(Dio(), 'sessions/s1');

  /// path → listing JSON (null = error 404)
  final Map<String, List<Map<String, dynamic>>> tree;
  final files = <String, Object>{}; // path → content String or BrowseError
  final listed = <String>[];
  final read_ = <String>[];

  @override
  Future<BrowseListing> list(String path) async {
    listed.add(path);
    final e = tree[path];
    if (e == null) throw BrowseError(404, 'not found');
    return BrowseListing(path: path, entries: [for (final j in e) BrowseEntry.tryFromJson(j)!]);
  }

  @override
  Future<TextDoc> readDoc(String path) async {
    read_.add(path);
    final f = files[path];
    if (f is BrowseError) throw f;
    return TextDoc(path: path, content: f as String, sha: 'sha-$path', mtime: null, size: f.length);
  }
}

void main() {
  group('sizeLabel', () {
    test('B / KB / MB', () {
      expect(sizeLabel(null), '');
      expect(sizeLabel(0), '0 B');
      expect(sizeLabel(812), '812 B');
      expect(sizeLabel(2048), '2 KB');
      expect(sizeLabel(1572864), '1.5 MB');
    });
  });

  group('BrowseEntry', () {
    test('parses; unreadable flag respected; junk is null', () {
      final e = BrowseEntry.tryFromJson(entry('.env', 'file', size: 20, readable: false))!;
      expect([e.name, e.isDir, e.size, e.readable], ['.env', false, 20, false]);
      expect(BrowseEntry.tryFromJson(entry('src', 'dir'))!.isDir, true);
      for (final bad in [null, 5, 'x', [], <String, dynamic>{}, {'name': 1, 'type': 'file'}, {'name': 'a'}]) {
        expect(BrowseEntry.tryFromJson(bad), isNull, reason: '$bad');
      }
      expect(BrowseEntry.tryFromJson({'name': 'a', 'type': 'file', 'readable': 'no'})!.readable, true, reason: 'only an explicit false hides it');
    });
  });

  group('BrowseApi', () {
    Dio stub(int status, Object? data, List<RequestOptions> seen) => Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        seen.add(o);
        h.resolve(Response(requestOptions: o, statusCode: status, data: data));
      }));

    test('list and read hit the session routes with the path as a query parameter', () async {
      final seen = <RequestOptions>[];
      final l = await BrowseApi(stub(200, {'path': 'src', 'entries': [entry('a.ts', 'file', size: 3), 7], 'truncated': true}, seen)).list('s1', 'src');
      expect([l.path, l.entries.length, l.truncated], ['src', 1, true]);
      expect([seen.single.path, seen.single.queryParameters], ['/sessions/s1/browse', {'path': 'src'}]);
      final seen2 = <RequestOptions>[];
      await BrowseApi(stub(200, {'path': 'src', 'entries': []}, seen2)).list('s1', '');
      expect(seen2.single.queryParameters, isEmpty, reason: 'the root sends no path');
      final seen3 = <RequestOptions>[];
      final f = await BrowseApi(stub(200, {'path': 'a.ts', 'size': 3, 'content': 'abc', 'truncated': false}, seen3)).read('s1', 'a.ts');
      expect([f.content, f.size, seen3.single.path], ['abc', 3, '/sessions/s1/browse/file']);
    });

    test('a refusal becomes a BrowseError with the status and the daemon\'s message', () async {
      await expectLater(BrowseApi(stub(403, {'error': 'this file looks like a secret'}, [])).read('s', '.env'), throwsA(isA<BrowseError>().having((e) => e.status, 'status', 403).having((e) => e.message, 'm', contains('secret'))));
      await expectLater(BrowseApi(stub(415, {'error': 'binary file'}, [])).read('s', 'x'), throwsA(isA<BrowseError>().having((e) => e.status, 'status', 415)));
      await expectLater(BrowseApi(stub(500, null, [])).list('s', ''), throwsA(isA<BrowseError>()));
    });
  });

  group('FileBrowserScreen', () {
    FakeApi tree() => FakeApi({
          '': [entry('src', 'dir'), entry('.env', 'file', size: 21, readable: false), entry('README.md', 'file', size: 17), entry('evil', 'link', readable: false)],
          'src': [entry('deep', 'dir'), entry('main.ts', 'file', size: 20)],
          'src/deep': [],
        })..files['README.md'] = '# hello\nline two\n'
          ..files['src/main.ts'] = 'export const x = 1;\n'
          ..files['bin.dat'] = BrowseError(415, 'binary file');

    Future<FakeApi> pump(WidgetTester t, [FakeApi? api]) async {
      final a = api ?? tree();
      await t.pumpWidget(ProviderScope(child: MaterialApp(home: FileBrowserScreen(title: 'Files', api: a))));
      await t.pumpAndSettle();
      return a;
    }

    testWidgets('lists the root; sizes shown; secrets and links are marked, not hidden', (t) async {
      await pump(t);
      expect(find.text('Files'), findsOneWidget);
      for (final n in ['src', '.env', 'README.md', 'evil']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('17 B'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.link_off), findsOneWidget);
    });

    testWidgets('a folder opens, shows its path, and ".." plus the system back go up', (t) async {
      final api = await pump(t);
      await t.tap(find.text('src'));
      await t.pumpAndSettle();
      expect(find.text('main.ts'), findsOneWidget);
      expect(find.text('src'), findsOneWidget, reason: 'now the app-bar title');
      await t.tap(find.text('..'));
      await t.pumpAndSettle();
      expect(find.text('README.md'), findsOneWidget);
      await t.tap(find.text('src'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute(); // the system back goes up a folder first, it does not leave the screen
      await t.pumpAndSettle();
      expect(find.text('README.md'), findsOneWidget);
      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(api.listed, ['', 'src', '', 'src', '']);
    });

    testWidgets('an empty folder says so', (t) async {
      await pump(t);
      await t.tap(find.text('src'));
      await t.pumpAndSettle();
      await t.tap(find.text('deep'));
      await t.pumpAndSettle();
      expect(find.text('Empty folder'), findsOneWidget);
    });

    testWidgets('a text file opens in the code editor with its contents', (t) async {
      final api = await pump(t);
      await t.tap(find.text('README.md'));
      await t.pumpAndSettle();
      expect(api.read_, ['README.md']);
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text, '# hello\nline two\n');
      expect(find.byTooltip('Save'), findsOneWidget);
    });

    testWidgets('onOpenFile replaces the pushed editor (the desktop workspace opens a tab)', (t) async {
      final api = tree();
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(home: FileBrowserScreen(title: 'Files', api: api, onOpenFile: (a, p) => opened.add('${a.scope}:$p'))));
      await t.pumpAndSettle();
      await t.tap(find.text('README.md'));
      await t.pumpAndSettle();
      expect(opened, ['sessions/s1:README.md']);
      expect(find.byType(CodeEditor), findsNothing);
      expect(api.read_, isEmpty);
    });

    testWidgets('a secret never reaches the API — just an explanation', (t) async {
      final api = await pump(t);
      await t.tap(find.text('.env'));
      await t.pump();
      expect(find.textContaining('looks like a secret'), findsOneWidget);
      expect(api.read_, isEmpty);
    });

    testWidgets('a link that leaves the project never reaches the API either', (t) async {
      final api = await pump(t);
      await t.tap(find.text('evil'));
      await t.pump();
      expect(find.textContaining('points outside the project'), findsOneWidget);
      expect(api.read_, isEmpty);
    });

    testWidgets('a binary file shows a plain message, not a stack trace', (t) async {
      final api = tree();
      api.tree['']!.add(entry('bin.dat', 'file', size: 9));
      await pump(t, api);
      await t.tap(find.text('bin.dat'));
      await t.pumpAndSettle();
      expect(find.textContaining('binary file'), findsOneWidget);
    });

    testWidgets('a failed listing shows the error, not a crash', (t) async {
      await t.pumpWidget(ProviderScope(child: MaterialApp(home: FileBrowserScreen(title: 'Files', api: FakeApi({})))));
      await t.pumpAndSettle();
      expect(find.textContaining('not found'), findsOneWidget);
    });
  });
}
