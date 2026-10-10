// ignore_for_file: invalid_use_of_visible_for_testing_member
// Proposal 47: a large paste collapses to a chip in the composer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  final log = List.generate(
    40,
    (i) => '2026-10-10 09:00:${'$i'.padLeft(2, '0')} INFO  GET /api/items/${100 + i} 200 ${12 + i}ms',
  ).join('\n');

  for (final size in [ShotSize.phone, ShotSize.desktop]) {
    testWidgets('paste collapse (${size.dir})', (tester) async {
      await startShot(tester, size);
      final c = fakeController('s1', [
        {'id': 'm1', 'role': 'user', 'content': 'The build is slow. I will paste the request log.', 'ts': '2026-10-10T09:00:00Z'},
        {'id': 'm2', 'role': 'assistant', 'content': 'Sure, paste it and I will look for slow requests.', 'ts': '2026-10-10T09:00:05Z'},
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [chatControllerPoolProvider.overrideWithValue(FakePool({}))],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          home: ChatScreen(creds: creds, session: fakeSession('s1', 'Slow requests'), controller: c),
        ),
      ));
      await settle(tester);
      await shot(tester, 'paste-collapse', size, 1, 'composer-empty');

      final field = find.byType(TextField).last;
      await tester.enterText(field, log);
      await tester.pump();
      await settle(tester);
      await shot(tester, 'paste-collapse', size, 2, 'pasted-chip');

      await tester.tapAt(tester.getTopLeft(field) + const Offset(90, 24));
      await settle(tester);
      expect(find.text('Expand inline'), findsOneWidget);
      await shot(tester, 'paste-collapse', size, 3, 'chip-sheet');

      await tester.tapAt(const Offset(10, 10)); // scrim
      await settle(tester);
      await tester.tap(find.byIcon(Icons.send));
      await settle(tester);
      c.applyFrame({'t': 'status', 'running': false}); // the fake never answers; drop the spinner
      await settle(tester);
      expect(find.textContaining('more lines'), findsOneWidget);
      await shot(tester, 'paste-collapse', size, 4, 'sent-folded');
      finishShot();
    });
  }
}
