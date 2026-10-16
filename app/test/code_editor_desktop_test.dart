import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vibemobile/features/editor/presentation/code_editor_screen.dart';
import 'package:vibemobile/features/files/data/project_files_api.dart';

import 'code_editor_test.dart' show FakeEditorApi;

// re_editor wires keyboard shortcuts only off Android/iOS, and decides that once per isolate, so
// the keyboard tests live in their own file and run as desktop.
void desktopTest(String name, Future<void> Function(WidgetTester t) body) {
  testWidgets(name, (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body(t);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<CodeLineEditingController> open(WidgetTester t, ProjectFilesApi api) async {
  await t.pumpWidget(ProviderScope(child: MaterialApp(home: CodeEditorScreen(api: api, path: 'a.txt'))));
  await t.pumpAndSettle();
  await t.tap(find.byType(CodeEditor));
  await t.pump();
  return t.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
}

Future<void> chord(WidgetTester t, LogicalKeyboardKey key, {bool shift = false}) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(key);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

void main() {
  desktopTest('Ctrl+S saves', (t) async {
    final api = FakeEditorApi();
    final c = await open(t, api);
    c.replaceSelection('X');
    await t.pump();
    await chord(t, LogicalKeyboardKey.keyS);
    await t.pumpAndSettle();
    expect(api.saves.map((s) => s.$2), ['helloX']);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  desktopTest('Ctrl+F opens find, Ctrl+H opens replace; the app bar has Find and no phone row', (t) async {
    final c = await open(t, FakeEditorApi());
    expect(c.text, 'hello');
    expect(find.byTooltip('Undo'), findsNothing);
    expect(find.byTooltip('Find'), findsOneWidget);
    Finder replaceField() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Replace');
    await chord(t, LogicalKeyboardKey.keyF);
    expect(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Find'), findsOneWidget);
    expect(replaceField(), findsNothing);
    await chord(t, LogicalKeyboardKey.keyH); // from inside the find field too
    expect(replaceField(), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  desktopTest('Ctrl+Z undoes; Ctrl+Y and Ctrl+Shift+Z redo', (t) async {
    final c = await open(t, FakeEditorApi());
    c.replaceSelection('X');
    await t.pump();
    expect(c.text, 'helloX');
    await chord(t, LogicalKeyboardKey.keyZ);
    expect(c.text, 'hello');
    await chord(t, LogicalKeyboardKey.keyY);
    expect(c.text, 'helloX');
    await chord(t, LogicalKeyboardKey.keyZ);
    await chord(t, LogicalKeyboardKey.keyZ, shift: true);
    expect(c.text, 'helloX');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  desktopTest('Tab indents and Shift+Tab outdents', (t) async {
    final c = await open(t, FakeEditorApi());
    c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(c.text, matches(RegExp(r'^\s+hello$')));
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(c.text, 'hello');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });

  desktopTest('Alt+Down moves the line', (t) async {
    final api = FakeEditorApi(content: 'one\ntwo');
    final c = await open(t, api);
    c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.pump();
    expect(c.text, 'two\none');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
