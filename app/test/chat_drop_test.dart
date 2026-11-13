import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_screen.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

void main() {
  Session session(String id) => Session(id: id, projectId: 'p-$id', kind: 'claude', status: 'live', createdAt: '2026-01-01T00:00:00Z');

  /// Feeds a native drag-and-drop through the desktop_drop channel, as the OS would.
  Future<void> drop(WidgetTester tester, Offset at, String path) async {
    const codec = StandardMethodCodec();
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final call in [MethodCall('entered', [at.dx, at.dy]), MethodCall('performOperation', [path])]) {
      await messenger.handlePlatformMessage('desktop_drop', codec.encodeMethodCall(call), (_) {});
    }
    await tester.pump();
  }

  // Tests run on the host (Linux) → isMobile is false → the DropTarget is live.
  testWidgets('a dropped file uploads from the visible chat only, not hidden workspace tabs', (tester) async {
    final dir = Directory.systemTemp.createTempSync('drop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/deck.pptx')..writeAsStringSync('x');

    final a = ChatSessionController(url: Uri.parse('ws://x/session/a'), token: 't');
    final b = ChatSessionController(url: Uri.parse('ws://x/session/b'), token: 't');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    Widget chat(String id, ChatSessionController c) => ScaffoldMessenger(
          key: ValueKey(id),
          child: ChatScreen(creds: const Creds('http://127.0.0.1:1', 't'), session: session(id), controller: c),
        );

    // Like WorkspaceScreen._panes: the active tab, plus a hidden tab kept alive under Visibility.
    Future<void> show(String active) => tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Stack(fit: StackFit.expand, children: [
              Visibility(visible: active == 'a', maintainState: true, child: chat('a', a)),
              Visibility(visible: active == 'b', maintainState: true, child: chat('b', b)),
            ]),
          ),
        ));

    // _uploadFiles flips the attach button to a spinner while the upload runs.
    Finder uploading(String id) => find.descendant(
          of: find.byKey(ValueKey(id), skipOffstage: false),
          matching: find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Attach image or file' && w.onPressed == null,
            skipOffstage: false,
          ),
          skipOffstage: false,
        );

    await show('a');
    await drop(tester, tester.getCenter(find.byKey(const ValueKey('a'))), file.path);
    expect(uploading('a'), findsOneWidget, reason: 'the visible chat handles the drop');
    expect(uploading('b'), findsNothing, reason: 'the hidden tab must not upload too');

    // Switching tabs moves the drop to the newly visible chat.
    await show('b');
    await drop(tester, tester.getCenter(find.byKey(const ValueKey('b'))), file.path);
    expect(uploading('b'), findsOneWidget, reason: 'the now-visible chat handles the drop');

    await tester.pump(const Duration(seconds: 10)); // let the (failing) uploads and their snackbars finish
  });
}
