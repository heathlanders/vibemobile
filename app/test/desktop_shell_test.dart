import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/dashboard/presentation/dashboard_screen.dart';
import 'package:vibemobile/features/dashboard/presentation/desktop_shell.dart';
import 'package:vibemobile/features/prompts/presentation/prompt_list_screen.dart';
import 'package:vibemobile/features/workspace/presentation/workspace_screen.dart';

void main() {
  const creds = Creds('http://127.0.0.1:1', 't');

  /// The pages fetch on mount (the test binding answers every request with a
  /// 400). Dio runs its stages on timers that need fake time to advance, then
  /// real time for the I/O; drain both so no timer outlives the test.
  Future<void> drainRequests(WidgetTester tester) async {
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('workspace: empty state, Ctrl+K opens the palette', (tester) async {
    // 1280 logical px: the default 3x ratio would make this window compact.
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: WorkspaceScreen(creds: creds))));
    await tester.pump();

    expect(find.text('No session open'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget); // sidebar header

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Open session…'), findsOneWidget);

    await drainRequests(tester);
  });

  testWidgets('rail swaps pages in place; dashboard drops its duplicate actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: DesktopShell(creds: creds))));

    expect(find.byType(NavigationRail), findsOneWidget);
    Finder rail(String label) => find.descendant(of: find.byType(NavigationRail), matching: find.text(label));
    expect(find.byType(WorkspaceScreen), findsOneWidget); // home page

    await tester.tap(rail('Projects'));
    await tester.pump();
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byTooltip('Prompt library'), findsNothing); // rail owns it now

    await tester.tap(rail('Prompts'));
    await tester.pump();
    expect(find.byType(PromptListScreen), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(find.byType(BackButton), findsNothing); // a page, not a pushed route
    // The workspace stays mounted (offstage) so its tabs keep their sockets.
    expect(find.byType(WorkspaceScreen, skipOffstage: false), findsOneWidget);

    await drainRequests(tester);
  });
}
