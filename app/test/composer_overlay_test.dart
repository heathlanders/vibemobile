import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/composer_overlay.dart';

void main() {
  testWidgets('renders nothing when there are no actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ComposerSuggestions(actions: [])),
    ));
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('lists actions and fires the tapped one', (tester) async {
    var picked = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ComposerSuggestions(actions: [
          ComposerAction(icon: Icons.bookmarks_outlined, label: '/prompt', onSelect: () => picked = 'prompt'),
          ComposerAction(icon: Icons.difference_outlined, label: '/files', onSelect: () => picked = 'files'),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    await tester.tap(find.text('/files'));
    expect(picked, 'files');
  });
}
