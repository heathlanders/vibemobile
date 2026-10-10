// Proposals 52 + 53: the floating toast, and the image viewer as a slideshow.
// Images come from bearer-gated daemon routes, so here they draw as their
// broken-image placeholder; the shot is for the viewer's chrome.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_image.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  for (final size in [ShotSize.phone, ShotSize.desktop]) {
    testWidgets('toast (${size.dir})', (tester) async {
      await startShot(tester, size);
      final c = fakeController('s1', overviewRows());
      addTearDown(c.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [chatControllerPoolProvider.overrideWithValue(FakePool({}))],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          builder: AppTheme.capToastWidth,
          home: ChatScreen(creds: creds, session: fakeSession('s1', 'Login flow'), controller: c),
        ),
      ));
      await settle(tester);
      ScaffoldMessenger.of(tester.element(find.byType(ChatScreen)))
          .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
      await settle(tester);
      await shot(tester, 'toast', size, 1, 'copied');
      finishShot();
    });

    testWidgets('image gallery (${size.dir})', (tester) async {
      await startShot(tester, size);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: ImageViewerScreen(
          creds: creds,
          sources: const [AttachmentImage('a1'), AttachmentImage('a2'), AttachmentImage('a3')],
          initialIndex: 1,
        ),
      ));
      await settle(tester);
      await shot(tester, 'image-gallery', size, 1, 'slideshow');
      finishShot();
    });
  }
}
