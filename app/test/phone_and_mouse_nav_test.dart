import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/providers.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/dashboard/presentation/desktop_shell.dart';
import 'package:vibemobile/features/prompts/presentation/prompt_list_screen.dart';
import 'package:vibemobile/features/settings/presentation/settings_screen.dart';
import 'package:vibemobile/features/workspace/presentation/workspace_screen.dart';
import 'package:vibemobile/main.dart';

void main() {
  const creds = Creds('http://127.0.0.1:1', 't');

  Future<void> drain(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(const Duration(milliseconds: 10));
    debugDefaultTargetPlatformOverride = null;
  }

  Future<bool> shownAt(WidgetTester tester, TargetPlatform p, double w, double h) async {
    debugDefaultTargetPlatformOverride = p;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(w, h);
    addTearDown(tester.view.reset);
    late bool shown;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      shown = DesktopShell.shown(context);
      return const SizedBox();
    })));
    debugDefaultTargetPlatformOverride = null;
    return shown;
  }

  testWidgets('DesktopShell.shown: phone never, windows always, tablet when wide', (tester) async {
    expect(await shownAt(tester, TargetPlatform.android, 915, 412), isFalse);
    expect(await shownAt(tester, TargetPlatform.android, 412, 915), isFalse);
    expect(await shownAt(tester, TargetPlatform.windows, 500, 400), isTrue);
    expect(await shownAt(tester, TargetPlatform.windows, 1920, 1080), isTrue);
    expect(await shownAt(tester, TargetPlatform.android, 1280, 800), isTrue);
  });

  Finder rail(String label) => find.descendant(of: find.byType(NavigationRail), matching: find.text(label));
  int selected(WidgetTester tester) => tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex!;

  Future<void> pumpApp(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [credsProvider.overrideWith((ref) async => creds)],
      child: const VibeMobileApp(),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> mouse(WidgetTester tester, int buttons) async {
    final g = await tester.startGesture(const Offset(700, 400), kind: PointerDeviceKind.mouse, buttons: buttons);
    await g.up();
    await tester.pump();
  }

  testWidgets('mouse back/forward walks the rail history', (tester) async {
    await pumpApp(tester);
    await tester.tap(rail('Prompts'));
    await tester.pump();
    await tester.tap(rail('Search'));
    await tester.pump();
    expect(selected(tester), 5);

    await mouse(tester, kBackMouseButton);
    expect(selected(tester), 4);
    expect(find.byType(PromptListScreen), findsOneWidget);
    await mouse(tester, kBackMouseButton);
    expect(selected(tester), 0);
    await mouse(tester, kBackMouseButton); // history exhausted: no-op
    expect(selected(tester), 0);
    await mouse(tester, kForwardMouseButton);
    expect(selected(tester), 4);

    // A new selection clears the forward stack.
    await tester.tap(rail('Settings'));
    await tester.pump();
    await mouse(tester, kForwardMouseButton);
    expect(selected(tester), 8);
    await drain(tester);
  });

  testWidgets('mouse back pops a pushed route before the shell history', (tester) async {
    await pumpApp(tester);
    await tester.tap(rail('Prompts'));
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('pushed'))));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    await mouse(tester, kBackMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing);
    expect(selected(tester), 4); // shell untouched

    await mouse(tester, kBackMouseButton);
    expect(selected(tester), 0);
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
    await drain(tester);
  });
}
