import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/presentation/chat_image.dart';

const _creds = Creds('https://box.example.ts.net', 'tok');
const _three = [AttachmentImage('a'), AttachmentImage('b'), AttachmentImage('c')];

Future<void> _open(WidgetTester tester, {List<ChatImageSource> gallery = _three}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatGallery(
      sources: gallery,
      child: const Scaffold(body: ChatImageStrip(creds: _creds, sources: [AttachmentImage('b')], size: 60)),
    ),
  ));
  await tester.tap(find.byType(ChatImageStrip));
  await tester.pumpAndSettle();
}

void main() {
  test('galleryFromMessages: chat order, each once, skips streaming', () {
    final msgs = [
      ChatMessage(role: ChatRole.user, images: ['u1', 'u2']),
      ChatMessage(role: ChatRole.assistant, text: 'wrote `out/a.png`'),
      ChatMessage(role: ChatRole.assistant, text: 'writing b.png', streaming: true),
      ChatMessage(role: ChatRole.tool, images: ['t1', 'u1']),
      ChatMessage(role: ChatRole.notice, text: 'x.png', images: ['n']),
    ];
    expect(galleryFromMessages(msgs, 's1'), [
      const AttachmentImage('u1'),
      const AttachmentImage('u2'),
      const SessionFileImage('s1', 'out/a.png'),
      const AttachmentImage('t1'),
    ]);
  });

  testWidgets('tap opens the whole-chat gallery at the tapped image', (tester) async {
    await _open(tester);
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('falls back to own sources without a gallery match', (tester) async {
    await _open(tester, gallery: const [AttachmentImage('x')]);
    expect(find.text('b'), findsOneWidget); // single image: file name title
  });

  testWidgets('Escape closes the viewer', (tester) async {
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsNothing);
  });

  testWidgets('backdrop tap closes; tap on the image does not', (tester) async {
    await _open(tester);
    // Error placeholder icon is the "image" here.
    await tester.tap(find.byIcon(Icons.broken_image_outlined).first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsOneWidget);
    await tester.tapAt(const Offset(400, 150));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsNothing);
  });

  testWidgets('arrow keys and buttons move through the slideshow', (tester) async {
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.byTooltip('Next'), findsNothing); // hidden at the end
    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byTooltip('Previous'), findsNothing);
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('tapping a thumbnail jumps to it', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('viewer-thumb-2')));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-thumb-0')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });
}
