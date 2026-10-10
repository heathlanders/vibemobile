// ignore_for_file: invalid_use_of_visible_for_testing_member
// Proposal 49: the desktop workspace (sidebar, tabs, split) and its compact mode.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/dashboard/presentation/desktop_shell.dart';

import 'fakes.dart';
import 'harness.dart';

Map<String, dynamic> _session(String id, String title) => {
      'id': id,
      'project_id': 'p1',
      'kind': 'claude',
      'status': 'live',
      'created_at': '2026-10-01T09:00:00Z',
      'title': title,
    };

void main() {
  final routes = <String, Object>{
    '/projects': [
      {'id': 'p1', 'path': '/workspace/demo-app', 'name': 'demo-app', 'type': 'node', 'git_branch': 'main', 'last_active': '2026-10-10T09:00:00Z'},
      {'id': 'p2', 'path': '/workspace/docs-site', 'name': 'docs-site', 'type': 'node', 'git_branch': 'main', 'last_active': '2026-10-09T09:00:00Z'},
    ],
    '/sessions': [
      _session('s1', 'Login flow'),
      _session('s2', 'Slow requests'),
      _session('s3', 'Add token refresh'),
    ],
    '/presets': {'presets': []},
    '/projects/p1/git-status': {
      'repo': true,
      'clean': false,
      'branch': 'main',
      'ahead': 1,
      'files': [
        {'path': 'src/auth/login.ts', 'index': ' ', 'worktree': 'M'},
        {'path': 'src/auth/refresh.ts', 'index': '?', 'worktree': '?'},
      ],
    },
    for (final id in ['s1', 's2'])
      '/sessions/$id/file-edits': [
        {'path': 'src/auth/login.ts', 'relPath': 'src/auth/login.ts', 'edits': 2, 'adds': 14, 'dels': 3, 'written': false, 'lastTs': '2026-10-10T09:30:00Z'},
        {'path': 'src/auth/refresh.ts', 'relPath': 'src/auth/refresh.ts', 'edits': 1, 'adds': 22, 'dels': 0, 'written': true, 'lastTs': '2026-10-10T09:31:00Z'},
      ],
  };

  /// Real time for the fake REST answers, then fake time for the widgets that wait on them.
  Future<void> load(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpShell(WidgetTester tester, ShotSize size) async {
    await startShot(tester, size);
    HttpOverrides.global = FakeHttp(routes);
    addTearDown(() => HttpOverrides.global = null);
    SharedPreferences.setMockInitialValues({
      'workspace_tab_ids': ['s1', 's2'],
      'workspace_active_id': 's1',
    });
    final pool = FakePool({
      's1': fakeController('s1', overviewRows()),
      's2': fakeController('s2', [
        {'id': 'm1', 'role': 'user', 'content': 'The build is slow. Where should I look first?', 'ts': '2026-10-10T09:00:00Z'},
        {'id': 'm2', 'role': 'assistant', 'content': 'Start with the request log: `src/server/log.ts` shows the slowest routes.', 'ts': '2026-10-10T09:00:05Z'},
      ]),
    });
    addTearDown(() {
      for (final c in pool.controllers.values) {
        c.dispose();
      }
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [chatControllerPoolProvider.overrideWithValue(pool)],
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: AppTheme.light, home: const DesktopShell(creds: creds)),
    ));
    await load(tester);
    await settle(tester);
  }

  testWidgets('desktop workspace (1440)', (tester) async {
    await pumpShell(tester, ShotSize.desktop);
    await tester.tap(find.text('demo-app').first);
    await load(tester);
    await settle(tester);
    await shot(tester, 'desktop-workspace', ShotSize.desktop, 1, 'sidebar-and-tabs');

    await tester.tap(find.byIcon(Icons.vertical_split_outlined));
    await load(tester);
    await settle(tester);
    await shot(tester, 'desktop-workspace', ShotSize.desktop, 2, 'split-view');
    finishShot();
  });

  testWidgets('desktop workspace (800 compact)', (tester) async {
    await pumpShell(tester, ShotSize.desktopCompact);
    await shot(tester, 'desktop-workspace', ShotSize.desktopCompact, 1, 'icon-rail');

    await tester.tap(find.byTooltip('Projects'));
    await settle(tester);
    await tester.tap(find.text('demo-app').first);
    await load(tester);
    await settle(tester);
    await shot(tester, 'desktop-workspace', ShotSize.desktopCompact, 2, 'sidebar-drawer');
    finishShot();
  });
}
