import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/workspace/data/workspace_prefs.dart';
import 'package:vibemobile/features/workspace/domain/work_tab.dart';
import 'package:vibemobile/features/workspace/presentation/workspace_screen.dart';

void main() {
  test('tab ids: session ids stay as they were; file tabs are prefixed and round-trip', () {
    expect(parseFileTabId('3f2a9c1e-77aa-4b0e-9d58-0c1b2a3d4e5f'), isNull);
    expect(parseFileTabId('s1'), isNull);
    final id = fileTabId('projects/p1', 'src/a|b.txt');
    expect(id, 'file:projects/p1|src/a|b.txt');
    expect(parseFileTabId(id), ('projects/p1', 'src/a|b.txt'));
    expect(parseFileTabId('file:no-bar'), isNull);
  });

  group('WorkspaceScreen file tabs', () {
    late HttpServer server;

    // flutter_test answers every HTTP request with a 400; these tests talk to a real local server.
    setUp(() => HttpOverrides.global = null);
    const fileId = 'file:projects/p1|src/a.txt';

    /// A tiny daemon: no projects or sessions; one readable file.
    Future<Creds> startServer(WidgetTester t) async {
      server = (await t.runAsync(() => HttpServer.bind('127.0.0.1', 0)))!;
      await t.runAsync(() async {
        server.listen((req) {
          final p = req.uri.path;
          req.response.headers.contentType = ContentType.json;
          if (p == '/projects/p1/files/text') {
            req.response.write(jsonEncode({'path': 'src/a.txt', 'content': 'hello', 'sha': 's1', 'mtime': 'm', 'size': 5}));
          } else if (p == '/sessions' || p == '/projects' || p == '/presets') {
            req.response.write('[]');
          } else {
            req.response.statusCode = 404;
            req.response.write('{"error":"not found"}');
          }
          req.response.close();
        });
      });
      addTearDown(() => server.close(force: true));
      return Creds('http://127.0.0.1:${server.port}', 't');
    }

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 25; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await t.pump(const Duration(milliseconds: 20));
        if (find.byType(CodeEditor).evaluate().isNotEmpty) return;
      }
    }

    Future<void> pumpWorkspace(WidgetTester t, Creds creds) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ProviderScope(child: MaterialApp(home: WorkspaceScreen(creds: creds))));
      await settle(t);
    }

    Future<void> release(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
    }

    testWidgets('a stored file tab reopens beside unknown session ids, which are dropped', (t) async {
      SharedPreferences.setMockInitialValues({
        'workspace_tab_ids': ['gone-session', fileId],
        'workspace_active_id': fileId,
      });
      final creds = await startServer(t);
      await pumpWorkspace(t, creds);
      expect(find.descendant(of: find.byType(InputChip), matching: find.text('a.txt')), findsOneWidget); // the tab
      expect(t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text, 'hello');
      final (ids, active) = await t.runAsync(WorkspacePrefs.load) as (List<String>, String?);
      expect(ids, [fileId]);
      expect(active, fileId);
      await release(t);
    });

    testWidgets('closing a dirty file tab asks first (button and Ctrl+W); a clean one closes', (t) async {
      SharedPreferences.setMockInitialValues({'workspace_tab_ids': [fileId], 'workspace_active_id': fileId});
      final creds = await startServer(t);
      await pumpWorkspace(t, creds);
      final dot = find.byKey(const ValueKey('tab-dirty-dot'));
      expect(dot, findsNothing);

      t.widget<CodeEditor>(find.byType(CodeEditor)).controller!.replaceSelection('X');
      await t.pump();
      expect(dot, findsOneWidget);

      await t.tap(find.byTooltip('Close file'));
      await t.pumpAndSettle();
      expect(find.text('Discard unsaved changes to a.txt?'), findsOneWidget);
      await t.tap(find.text('Keep editing'));
      await t.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);

      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyW);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
      expect(find.text('Discard unsaved changes to a.txt?'), findsOneWidget);
      await t.tap(find.text('Discard'));
      await t.pumpAndSettle();
      expect(find.byType(CodeEditor), findsNothing);
      expect(find.text('No session open'), findsOneWidget);
      final (ids, _) = await t.runAsync(WorkspacePrefs.load) as (List<String>, String?);
      expect(ids, isEmpty);
      await release(t);
    });

    testWidgets('a clean file tab closes without a prompt', (t) async {
      SharedPreferences.setMockInitialValues({'workspace_tab_ids': [fileId], 'workspace_active_id': fileId});
      final creds = await startServer(t);
      await pumpWorkspace(t, creds);
      await t.tap(find.byTooltip('Close file'));
      await t.pumpAndSettle();
      expect(find.textContaining('Discard'), findsNothing);
      expect(find.byType(CodeEditor), findsNothing);
      await release(t);
    });
  });
}
