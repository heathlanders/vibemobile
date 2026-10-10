// Proposal 06: drag-select a reply on desktop and copy it with its line breaks.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  testWidgets('copy selection (desktop)', (tester) async {
    await startShot(tester, ShotSize.desktop);
    final c = fakeController('s1', overviewRows());
    addTearDown(c.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [chatControllerPoolProvider.overrideWithValue(FakePool({}))],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: ChatScreen(creds: creds, session: fakeSession('s1', 'Login flow'), controller: c),
      ),
    ));
    await settle(tester);
    await shot(tester, 'copy-selection', ShotSize.desktop, 1, 'reply');

    tester.state<SelectableRegionState>(find.byType(SelectableRegion).first).selectAll();
    await settle(tester);
    await shot(tester, 'copy-selection', ShotSize.desktop, 2, 'selected');
    finishShot();
  });
}
