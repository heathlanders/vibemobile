// ignore_for_file: invalid_use_of_visible_for_testing_member
// Proposal 54: the phone shell, dark theme: panel open, then a chat open.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/session_attention.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/phone/presentation/phone_shell.dart';

import 'fakes.dart';
import 'harness.dart';

Map<String, dynamic> _session(String id, String project, String title, {String status = 'live'}) => {
      'id': id,
      'project_id': project,
      'kind': 'claude',
      'status': status,
      'created_at': '2026-10-01T09:00:00Z',
      'title': title,
      'claude_session_id': 'c-$id',
    };

void main() {
  final routes = <String, Object>{
    '/projects': [
      {'id': 'p1', 'path': '/workspace/demo-app', 'name': 'demo-app', 'git_branch': 'main', 'last_active': '2026-10-10T09:00:00Z'},
      {'id': 'p2', 'path': '/workspace/docs-site', 'name': 'docs-site', 'git_branch': 'main', 'last_active': '2026-10-09T09:00:00Z'},
      {'id': 'p3', 'path': '/workspace/api', 'name': 'api', 'last_active': '2026-10-08T09:00:00Z'},
    ],
    '/sessions': [
      _session('s1', 'p1', 'Login flow'),
      _session('s2', 'p1', 'Slow requests'),
      _session('s4', 'p1', 'Add token refresh', status: 'idle'),
      _session('s3', 'p2', 'Fix broken links'),
    ],
    '/presets': {'presets': []},
  };

  Future<void> load(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('phone shell (phone)', (tester) async {
    await startShot(tester, ShotSize.phone);
    HttpOverrides.global = FakeHttp(routes);
    addTearDown(() => HttpOverrides.global = null);
    SharedPreferences.setMockInitialValues({});
    final pool = FakePool({'s1': fakeController('s1', overviewRows())});
    addTearDown(() {
      for (final c in pool.controllers.values) {
        c.dispose();
      }
    });
    final container = ProviderContainer(overrides: [chatControllerPoolProvider.overrideWithValue(pool)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: AppTheme.dark, home: const PhoneShell(creds: creds)),
    ));
    await load(tester);
    container.read(sessionAttentionProvider.notifier).raise('s2', Attention.needsInput);
    await settle(tester);
    await shot(tester, 'phone-shell', ShotSize.phone, 1, 'panel-open');

    await tester.tap(find.text('Login flow'));
    await load(tester);
    await settle(tester);
    await shot(tester, 'phone-shell', ShotSize.phone, 2, 'chat-open');
    finishShot();
  });
}
