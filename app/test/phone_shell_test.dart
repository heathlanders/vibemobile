// Proposal 54: the phone shell (Discord-style panel over the open session).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/session_attention.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/phone/presentation/phone_shell.dart';
import 'package:vibemobile/features/phone/presentation/you_screen.dart';
import 'package:vibemobile/features/sessions/presentation/session_search_screen.dart';

import '../screenshots/fakes.dart';

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
      {'id': 'p1', 'path': '/workspace/demo-app', 'name': 'demo-app', 'last_active': '2026-10-10T09:00:00Z'},
      {'id': 'p2', 'path': '/workspace/docs-site', 'name': 'docs-site', 'last_active': '2026-10-09T09:00:00Z'},
    ],
    '/sessions': [
      _session('s1', 'p1', 'Login flow'),
      _session('s2', 'p1', 'Old idea', status: 'idle'),
      _session('s3', 'p2', 'Fix links'),
    ],
    '/presets': {'presets': []},
  };

  Future<void> load(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  late ProviderContainer container;

  Future<void> pumpShell(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    HttpOverrides.global = FakeHttp(routes);
    addTearDown(() => HttpOverrides.global = null);
    SharedPreferences.setMockInitialValues(prefs);
    final pool = FakePool({
      's1': fakeController('s1', overviewRows()),
      's3': fakeController('s3', overviewRows()),
    });
    addTearDown(() {
      for (final c in pool.controllers.values) {
        c.dispose();
      }
    });
    container = ProviderContainer(overrides: [chatControllerPoolProvider.overrideWithValue(pool)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: const PhoneShell(creds: creds)),
    ));
    await load(tester);
  }

  // Content sits at the left edge when closed, at width - peek when open.
  double contentLeft(WidgetTester tester) => tester.getTopLeft(find.byType(Scaffold).at(1)).dx;

  testWidgets('starts with the panel open on the most recent project', (tester) async {
    await pumpShell(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('demo-app'), findsWidgets);
    expect(find.text('Login flow'), findsOneWidget);
    expect(find.text('Fix links'), findsNothing); // other project
    expect(find.text('New chat'), findsOneWidget);
    expect(contentLeft(tester), 412 - PhoneShell.peek);
  });

  testWidgets('tapping a session closes the panel and shows it; bottom bar is panel-only', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Login flow'));
    await load(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(contentLeft(tester), 0);
    expect((await SharedPreferences.getInstance()).getString('phone_last_session_id'), 's1');
  });

  testWidgets('menu button opens the panel', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Login flow'));
    await load(tester);
    await tester.tap(find.byTooltip('Menu'));
    await load(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(contentLeft(tester), 412 - PhoneShell.peek);
  });

  testWidgets('swipe right opens, swipe left closes, tapping the sliver closes', (tester) async {
    await pumpShell(tester, prefs: {'phone_last_session_id': 's1'});
    expect(find.byType(ChatScreen), findsOneWidget); // remembered session restored behind the panel
    await tester.tap(find.widgetWithText(ListTile, 'Login flow'));
    await load(tester);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.fling(find.byType(AppBar).last, const Offset(300, 0), 1500);
    await load(tester);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.fling(find.text('demo-app').first, const Offset(-300, 0), 1500);
    await load(tester);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.fling(find.byType(AppBar).last, const Offset(300, 0), 1500);
    await load(tester);
    await tester.tapAt(const Offset(412 - 20, 400)); // the visible sliver
    await load(tester);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('a vertical drag does not open the panel', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Login flow'));
    await load(tester);
    await tester.fling(find.byType(ChatScreen), const Offset(10, 400), 1500);
    await load(tester);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('back with a session showing opens the panel; back on the panel leaves', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Login flow'));
    await load(tester);
    await tester.binding.handlePopRoute();
    await load(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(PhoneShell), findsOneWidget);
  });

  testWidgets('Live badge counts sessions needing attention and Live lists them', (tester) async {
    await pumpShell(tester);
    container.read(sessionAttentionProvider.notifier)
      ..raise('s1', Attention.done)
      ..raise('s3', Attention.needsInput);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('2'), findsWidgets); // rail + bottom bar
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Live')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Fix links'), findsOneWidget);
    expect(find.text('Login flow'), findsOneWidget);
    expect(find.text('docs-site'), findsOneWidget); // project name under a live session
    expect(find.text('New chat'), findsNothing);
  });

  testWidgets('empty content, search and You', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Search'));
    await load(tester);
    expect(find.byType(SessionSearchScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(SessionSearchScreen))).pop();
    await load(tester);
    await tester.tap(find.text('You'));
    await load(tester);
    expect(find.byType(YouScreen), findsOneWidget);
    for (final t in ['Usage', 'Prompt library', 'Multi-chat', 'Settings']) {
      expect(find.text(t), findsOneWidget);
    }
  });

  testWidgets('empty content shows the hint once the panel is closed', (tester) async {
    await pumpShell(tester);
    await tester.tapAt(const Offset(412 - 20, 400));
    await load(tester);
    expect(find.text('Pick a session'), findsOneWidget);
    expect(find.text('Swipe right or tap ☰'), findsOneWidget);
  });
}
