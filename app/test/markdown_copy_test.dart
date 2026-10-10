import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/markdown_text.dart';

/// Proposal 06 bug (2026-10-10): drag-select copy on desktop must keep the
/// line breaks between markdown blocks, not only inside them.
void main() {
  Future<String> selectAllAndCopy(WidgetTester tester, String md) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SelectionArea(child: MarkdownText(md)))));
    // Each nested selection container registers with its parent a frame later.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    // ignore: deprecated_member_use // the same path as Ctrl+C, without driving focus
    region.copySelection(SelectionChangedCause.keyboard);
    await tester.pumpAndSettle();
    return copied ?? '';
  }

  testWidgets('paragraphs keep their line breaks', (tester) async {
    expect(await selectAllAndCopy(tester, 'one\ntwo\n\nthree'), 'one\ntwo\n\nthree');
  });

  testWidgets('headings and list items are on their own lines', (tester) async {
    expect(await selectAllAndCopy(tester, '# Title\n\n- a\n- b\n\nend'), 'Title\n\n• a\n• b\n\nend');
  });

  testWidgets('code block lines survive, without the header', (tester) async {
    expect(await selectAllAndCopy(tester, 'before\n\n```dart\nx = 1\ny = 2\n```\n\nafter'), 'before\n\nx = 1\ny = 2\n\nafter');
  });

  // Known limit: cells inside the table's horizontal scroller still copy
  // run together; the table must at least not drop out of the selection.
  testWidgets('a table still copies alongside other blocks', (tester) async {
    final text = await selectAllAndCopy(tester, 'intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nouttro');
    expect(text, startsWith('intro\n\n'));
    expect(text, contains('ab12'));
    expect(text, endsWith('\n\nouttro'));
  });
}
