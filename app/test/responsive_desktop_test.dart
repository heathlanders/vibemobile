import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/providers.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/dashboard/presentation/dashboard_screen.dart';
import 'package:vibemobile/features/dashboard/presentation/desktop_shell.dart';
import 'package:vibemobile/features/workspace/presentation/workspace_screen.dart';
import 'package:vibemobile/main.dart';

void main() {
  const creds = Creds('http://127.0.0.1:1', 't');

  /// Override the platform; reset before the binding's invariant check runs.
  void setPlatform(TargetPlatform p) {
    debugDefaultTargetPlatformOverride = p;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  /// Same drain as desktop_shell_test: the pages fetch on mount.
  Future<void> drainRequests(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(const Duration(milliseconds: 10));
    // Last step of every test: the binding checks debug vars before tearDowns run.
    debugDefaultTargetPlatformOverride = null;
  }

  /// Logical window size (the test view defaults to a 3x pixel ratio).
  void setWindow(WidgetTester tester, double w, double h) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(w, h);
    addTearDown(tester.view.reset);
  }

  Future<void> pumpApp(WidgetTester tester, double width) async {
    SharedPreferences.setMockInitialValues({});
    setWindow(tester, width, 800);
    await tester.pumpWidget(ProviderScope(
      overrides: [credsProvider.overrideWith((ref) async => creds)],
      child: const VibeMobileApp(),
    ));
    await tester.pump();
    await tester.pump();
  }

  NavigationRail rail(WidgetTester tester) => tester.widget<NavigationRail>(find.byType(NavigationRail));
  IconButton splitButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.vertical_split_outlined));
  IconButton changesButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.difference_outlined));

  for (final (width, compact) in [(700.0, true), (1000.0, false), (1400.0, false)]) {
    testWidgets('windows at ${width.toInt()} px: shell, ${compact ? 'compact' : 'full'} layout', (tester) async {
      setPlatform(TargetPlatform.windows);
      await pumpApp(tester, width);

      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(rail(tester).labelType, compact ? NavigationRailLabelType.none : NavigationRailLabelType.all);

      // Sidebar: inline when wide, behind a toggle (drawer) when compact.
      expect(find.byTooltip('Projects'), compact ? findsOneWidget : findsNothing);
      if (compact) {
        expect(find.widgetWithText(ListTile, 'Projects'), findsNothing); // closed drawer
        await tester.tap(find.byTooltip('Projects'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'Projects'), findsOneWidget); // drawer header
        await tester.tapAt(Offset(width - 5, 400)); // dismiss via the scrim
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'Projects'), findsNothing);
      } else {
        expect(rail(tester).labelType, NavigationRailLabelType.all);
        expect(find.widgetWithText(ListTile, 'Projects'), findsOneWidget);
      }

      // Split + changes toggles: disabled when compact.
      expect(splitButton(tester).onPressed == null, compact);
      expect(changesButton(tester).onPressed == null, compact);

      // Ctrl+K still opens the palette.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Open session…'), findsOneWidget);

      await drainRequests(tester);
    });
  }

  testWidgets('windows: widening from compact restores sidebar and toggles', (tester) async {
    setPlatform(TargetPlatform.windows);
    await pumpApp(tester, 700);
    expect(find.byTooltip('Projects'), findsOneWidget);
    setWindow(tester, 1400, 800);
    await tester.pump();
    expect(find.byTooltip('Projects'), findsNothing);
    expect(rail(tester).labelType, NavigationRailLabelType.all);
    expect(splitButton(tester).onPressed, isNotNull);
    await drainRequests(tester);
  });

  testWidgets('windows at 600x500: no overflow', (tester) async {
    setPlatform(TargetPlatform.windows);
    setWindow(tester, 600, 500);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: DesktopShell(creds: creds))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await drainRequests(tester);
  });

  testWidgets('android at 700 px: phone layout unchanged', (tester) async {
    setPlatform(TargetPlatform.android);
    await pumpApp(tester, 700);
    expect(find.byType(DesktopShell), findsNothing);
    expect(find.byType(DashboardScreen), findsOneWidget);
    await drainRequests(tester);
  });

  testWidgets('android at 1400 px: wide tablets still get the shell', (tester) async {
    setPlatform(TargetPlatform.android);
    await pumpApp(tester, 1400);
    expect(find.byType(DesktopShell), findsOneWidget);
    await drainRequests(tester);
  });
}
