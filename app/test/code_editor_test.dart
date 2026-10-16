import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vibemobile/features/chat/data/browse_api.dart';
import 'package:vibemobile/features/chat/presentation/file_browser_screen.dart';
import 'package:vibemobile/features/editor/presentation/editor_opener.dart';
import 'package:vibemobile/features/chat/presentation/diff_lines.dart';
import 'package:vibemobile/features/chat/presentation/markdown_text.dart';
import 'package:vibemobile/features/editor/domain/editor_language.dart';
import 'package:vibemobile/features/editor/domain/line_diff.dart';
import 'package:vibemobile/features/editor/presentation/code_editor_screen.dart';
import 'package:vibemobile/features/editor/presentation/code_view.dart';
import 'package:vibemobile/features/files/data/project_files_api.dart';

class FakeEditorApi extends ProjectFilesApi {
  FakeEditorApi({this.content = 'hello', this.sha = 'sha1', this.failWith}) : super(Dio(), 'projects/p1');
  String content;
  String sha;
  BrowseError? failWith;
  int reads = 0;
  final saves = <(String, String, String?)>[];

  /// Answers the next saves with a 409 carrying this sha (cleared after one).
  String? staleSha;

  @override
  Future<TextDoc> readDoc(String path) async {
    reads++;
    if (failWith != null) throw failWith!;
    return TextDoc(path: path, content: content, sha: sha, mtime: 'm', size: content.length);
  }

  @override
  Future<SaveResult> saveText(String path, String content, {String? baseSha, bool create = false}) async {
    saves.add((path, content, baseSha));
    final s = staleSha;
    if (s != null) {
      staleSha = null;
      throw StaleFileError('changed since you opened it', s);
    }
    this.content = content;
    sha = 'sha${saves.length + 1}';
    return SaveResult(sha: sha, mtime: 'm2', size: content.length);
  }
}

Future<CodeLineEditingController> pumpEditor(WidgetTester t, FakeEditorApi api, {String path = 'src/a.txt', int? line, bool readOnly = false, Brightness brightness = Brightness.light}) async {
  await t.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: CodeEditorScreen(api: api, path: path, line: line, readOnly: readOnly),
    ),
  ));
  await t.pumpAndSettle();
  return t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
}

/// Find (and highlighting) run in an isolate: give it real time, then let the frame land.
Future<void> isolateWork(WidgetTester t) async {
  final fc = t.widget<CodeEditor>(find.byType(CodeEditor)).findController!;
  for (var i = 0; i < 20; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
    if (fc.value?.searching != true && fc.value?.result != null) return;
  }
}

Finder dirtyDot() => find.byKey(const ValueKey('dirty-dot'));

void main() {
  group('languageFor', () {
    test('maps extensions and well-known file names; unknown is plaintext', () {
      expect(languageFor('lib/a.dart'), 'dart');
      expect(languageFor('a.tsx'), 'typescript');
      expect(languageFor('a.MJS'), 'javascript');
      expect(languageFor('a.yml'), 'yaml');
      expect(languageFor('x/Dockerfile'), 'dockerfile');
      expect(languageFor('Makefile'), 'makefile');
      expect(languageFor('build.gradle'), 'gradle');
      expect(languageFor('Cargo.toml'), 'ini');
      expect(languageFor('notes.xyz'), plaintextLanguage);
      expect(languageFor('LICENSE'), plaintextLanguage);
      for (final p in ['a.dart', 'a.ts', 'a.js', 'a.json', 'a.yaml', 'a.md', 'a.py', 'a.sh', 'a.kt', 'a.java', 'a.swift', 'a.go', 'a.rs', 'a.c', 'a.h', 'a.cpp', 'a.cs', 'a.html', 'a.css', 'a.scss', 'a.xml', 'a.sql', 'a.toml', 'a.ini']) {
        expect(modeFor(languageFor(p)), isNotNull, reason: p);
      }
    });
  });

  group('lineDiff', () {
    test('equal texts have no diff; changes show with context', () {
      expect(lineDiff('a\nb', 'a\nb'), isEmpty);
      expect(lineDiff('a\nb\nc', 'a\nB\nc', context: 1), [' a', '-b', '+B', ' c']);
      final long = List.generate(20, (i) => 'l$i').join('\n');
      expect(lineDiff(long, long.replaceFirst('l10', 'X'), context: 1), ['…', ' l9', '-l10', '+X', ' l11', '…']);
    });
    test('pure insertions and deletions', () {
      expect(lineDiff('a\nc', 'a\nb\nc', context: 0), ['…', '+b', '…']);
      expect(lineDiff('a\nb\nc', 'a\nc', context: 0), ['…', '-b', '…']);
    });
  });

  test('EditorShortcuts adds Ctrl+Y and Ctrl+H to the defaults', () {
    const b = EditorShortcuts();
    bool has(CodeShortcutType t, LogicalKeyboardKey k, {bool shift = false}) =>
        b.build(t)!.any((a) => a is SingleActivator && a.trigger == k && a.control && a.shift == shift);
    expect(has(CodeShortcutType.redo, LogicalKeyboardKey.keyY), isTrue);
    expect(has(CodeShortcutType.redo, LogicalKeyboardKey.keyZ, shift: true), isTrue);
    expect(has(CodeShortcutType.replace, LogicalKeyboardKey.keyH), isTrue);
    expect(has(CodeShortcutType.undo, LogicalKeyboardKey.keyZ), isTrue);
    expect(has(CodeShortcutType.find, LogicalKeyboardKey.keyF), isTrue);
    expect(has(CodeShortcutType.save, LogicalKeyboardKey.keyS), isTrue);
    expect(b.build(CodeShortcutType.indent), isNotNull);
    expect(b.build(CodeShortcutType.lineMoveUp), isNotNull);
  });

  group('CodeEditorScreen', () {
    testWidgets('open, edit, dirty dot, save sends baseSha and clears the dot', (t) async {
      final api = FakeEditorApi();
      final c = await pumpEditor(t, api);
      expect(c.text, 'hello');
      expect(dirtyDot(), findsNothing);
      c.replaceSelection('X');
      await t.pump();
      expect(c.text, 'Xhello');
      expect(dirtyDot(), findsOneWidget);
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      expect(api.saves, [('src/a.txt', 'Xhello', 'sha1')]);
      expect(dirtyDot(), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      // The next save quotes the hash the last one returned.
      c.replaceSelection('Y');
      await t.pump();
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      expect(api.saves.last.$3, 'sha2');
    });

    testWidgets('a 409 offers Overwrite, which retries with the sha the 409 returned', (t) async {
      final api = FakeEditorApi()..staleSha = 'server-sha';
      final c = await pumpEditor(t, api);
      c.replaceSelection('X');
      await t.pump();
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      expect(find.text('File changed on the server'), findsOneWidget);
      await t.tap(find.text('Overwrite'));
      await t.pumpAndSettle();
      expect(api.saves.map((s) => s.$3), ['sha1', 'server-sha']);
      expect(dirtyDot(), findsNothing);
      expect(find.text('File changed on the server'), findsNothing);
    });

    testWidgets('a 409 Reload discards the edits and shows the server\'s text', (t) async {
      final api = FakeEditorApi()..staleSha = 'server-sha';
      final c = await pumpEditor(t, api);
      c.replaceSelection('X');
      await t.pump();
      api.content = 'changed elsewhere';
      api.sha = 'server-sha';
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reload'));
      await t.pumpAndSettle();
      expect(api.reads, 2);
      expect(api.saves, hasLength(1));
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text, 'changed elsewhere');
      expect(dirtyDot(), findsNothing);
    });

    testWidgets('a 409 Show diff compares the server\'s copy with the buffer, then returns to the choice', (t) async {
      final api = FakeEditorApi(content: 'one\ntwo')..staleSha = 'server-sha';
      final c = await pumpEditor(t, api);
      api.content = 'one\nserver';
      c.replaceSelection('X');
      await t.pump();
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      await t.tap(find.text('Show diff'));
      await t.pumpAndSettle();
      expect(find.byType(DiffLine), findsWidgets);
      expect(find.text('-server'), findsOneWidget); // the server's copy
      expect(find.text('+Xone'), findsOneWidget); // the buffer
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('File changed on the server'), findsOneWidget);
    });

    testWidgets('find and replace all', (t) async {
      final api = FakeEditorApi(content: 'foo bar foo');
      final c = await pumpEditor(t, api);
      await t.tap(find.byTooltip('Find'));
      await t.pump();
      final fc = t.widget<CodeEditor>(find.byType(CodeEditor)).findController!;
      fc.replaceMode();
      await t.pump();
      Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);
      await t.enterText(field('Find'), 'foo');
      await isolateWork(t);
      expect(find.text('1/2'), findsOneWidget);
      await t.enterText(field('Replace'), 'baz');
      await t.pump();
      await t.tap(find.byTooltip('Replace All'));
      await isolateWork(t);
      expect(c.text, 'baz bar baz');
      expect(dirtyDot(), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('the regex toggle changes what matches', (t) async {
      final api = FakeEditorApi(content: 'a1 b22');
      await pumpEditor(t, api);
      await t.tap(find.byTooltip('Find'));
      await t.pump();
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Find'), r'\d+');
      await isolateWork(t);
      expect(find.text('none'), findsOneWidget);
      await t.tap(find.text('.*'));
      await isolateWork(t);
      expect(find.text('1/2'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('opens on the requested line', (t) async {
      final api = FakeEditorApi(content: List.generate(60, (i) => 'line $i').join('\n'));
      final c = await pumpEditor(t, api, line: 42);
      expect(c.selection.baseIndex, 41);
    });

    testWidgets('markdown previews through MarkdownText and back', (t) async {
      final api = FakeEditorApi(content: '# Title\n\nsome **bold** text');
      await pumpEditor(t, api, path: 'README.md');
      expect(find.byType(MarkdownText), findsNothing);
      await t.tap(find.byTooltip('Preview'));
      await t.pumpAndSettle();
      expect(find.byType(MarkdownText), findsOneWidget);
      await t.tap(find.byTooltip('Edit'));
      await t.pumpAndSettle();
      expect(find.byType(MarkdownText).hitTestable(), findsNothing);
    });

    testWidgets('JSON previews pretty-printed; invalid JSON falls back to the raw text', (t) async {
      await pumpEditor(t, FakeEditorApi(content: '{"a":1,"b":[true]}'), path: 'x.json');
      await t.tap(find.byTooltip('Preview'));
      await t.pumpAndSettle();
      expect(find.textContaining('"a": 1', findRichText: true), findsOneWidget);
      expect(find.textContaining('\n  "b": [', findRichText: true), findsOneWidget);
    });

    testWidgets('invalid JSON previews as written', (t) async {
      await pumpEditor(t, FakeEditorApi(content: '{oops'), path: 'x.json');
      await t.tap(find.byTooltip('Preview'));
      await t.pumpAndSettle();
      expect(find.text('{oops'), findsOneWidget);
    });

    testWidgets('a plain file has no preview button', (t) async {
      await pumpEditor(t, FakeEditorApi(), path: 'a.dart');
      expect(find.byTooltip('Preview'), findsNothing);
    });

    testWidgets('read-only: the editor is read-only and nothing can be saved', (t) async {
      final api = FakeEditorApi();
      await pumpEditor(t, api, readOnly: true);
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).readOnly, isTrue);
      expect(find.byTooltip('Save'), findsNothing);
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(dirtyDot(), findsNothing);
    });

    testWidgets('dark theme still renders (vs2015)', (t) async {
      final c = await pumpEditor(t, FakeEditorApi(content: 'void main() {}'), path: 'a.dart', brightness: Brightness.dark);
      expect(c.text, 'void main() {}');
    });

    testWidgets('CRLF files keep their line endings through a save', (t) async {
      final api = FakeEditorApi(content: 'a\r\nb\r\n');
      final c = await pumpEditor(t, api);
      c.replaceSelection('X');
      await t.pump();
      await t.tap(find.byTooltip('Save'));
      await t.pumpAndSettle();
      expect(api.saves.single.$2, 'Xa\r\nb\r\n');
    });

    for (final (status, expectDownload) in [(413, true), (415, true), (403, false)]) {
      testWidgets('a $status shows a message${expectDownload ? ' and offers Download' : ' and no Download'}', (t) async {
        final api = FakeEditorApi(failWith: BrowseError(status, 'refused'));
        await t.pumpWidget(ProviderScope(child: MaterialApp(home: CodeEditorScreen(api: api, path: 'big.bin'))));
        await t.pumpAndSettle();
        expect(find.byType(CodeEditor), findsNothing);
        expect(find.text('Download'), expectDownload ? findsOneWidget : findsNothing);
        expect(find.textContaining(status == 413 ? 'too large' : (status == 415 ? 'binary' : 'secret')), findsOneWidget);
      });
    }

    testWidgets('leaving with unsaved edits asks first; a clean buffer leaves silently', (t) async {
      final api = FakeEditorApi();
      await t.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CodeEditorScreen(api: api, path: 'a.txt'))), child: const Text('open')),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      // Clean: back leaves with no dialog.
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.replaceSelection('X');
      await t.pump();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await t.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(find.text('Discard'));
      await t.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);
    });

    testWidgets('a phone gets the Select all / Undo / Redo / Find row', (t) async {
      final api = FakeEditorApi();
      final c = await pumpEditor(t, api); // the test platform is Android
      expect(find.byTooltip('Undo'), findsOneWidget);
      expect(find.byTooltip('Redo'), findsOneWidget);
      expect(c.canUndo, isFalse);
      c.replaceSelection('Z');
      await t.pumpAndSettle();
      expect(c.canUndo, isTrue);
      await t.tap(find.byTooltip('Undo'));
      await t.pumpAndSettle();
      expect(c.text, 'hello');
      await t.tap(find.byTooltip('Redo'));
      await t.pumpAndSettle();
      expect(c.text, 'Zhello');
      await t.tap(find.byTooltip('Select all'));
      await t.pumpAndSettle();
      expect(c.isAllSelected, isTrue);
      await t.tap(find.byTooltip('Find'));
      await t.pump();
      expect(find.byType(TextField), findsWidgets);
    });
  });

  group('openChatFile', () {
    testWidgets('pushes the editor at the line', (t) async {
      final api = FakeEditorApi(content: List.generate(30, (i) => 'l$i').join('\n'));
      await t.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Builder(builder: (context) => TextButton(onPressed: () => openChatFile(context, sessionId: 's1', path: 'lib/a.dart', line: 12, api: api), child: const Text('go'))),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.selection.baseIndex, 11);
    });

    testWidgets('inside the desktop workspace it asks for a tab instead of pushing a route', (t) async {
      final api = FakeEditorApi();
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
        home: EditorOpener(
          open: (a, path, {line}) => opened.add('$path:$line'),
          child: Builder(builder: (context) => TextButton(onPressed: () => openChatFile(context, sessionId: 's1', path: 'lib/a.dart', line: 12, api: api), child: const Text('go'))),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(opened, ['lib/a.dart:12']);
      expect(find.byType(CodeEditor), findsNothing);
      expect(api.reads, 0);
    });
  });

  testWidgets('ReadOnlyCodeView shows the text and ignores edits', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: ReadOnlyCodeView(text: 'a\nb', path: 'x.dart'))));
    await t.pumpAndSettle();
    final e = t.widget<CodeEditor>(find.byType(CodeEditor));
    expect(e.readOnly, isTrue);
    expect(e.controller!.text, 'a\nb');
  });
}
