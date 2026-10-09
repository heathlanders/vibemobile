import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/dashboard/presentation/dashboard_screen.dart';

Future<void> pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(theme: AppTheme.dark, home: const DashboardScreen(creds: Creds('http://127.0.0.1:1', 't'))),
  ));
}

void main() {
  testWidgets('phone under 360 dp: two icons + an overflow menu with the rest', (tester) async {
    await pumpAt(tester, 340);
    expect(find.byTooltip('Search sessions'), findsOneWidget);
    expect(find.byTooltip('Prompt library'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsNothing);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    for (final t in ['Live sessions', 'Multi-chat', 'Usage', 'Settings']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(tester.takeException(), isNull, reason: 'no app bar overflow');
  });

  testWidgets('360 dp and wider: all six icons, no overflow menu', (tester) async {
    await pumpAt(tester, 411);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('More'), findsNothing);
    await tester.pumpAndSettle(); // let the (unreachable) dashboard fetch fail out
  });
}
