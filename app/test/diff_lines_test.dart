import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/diff_lines.dart';

/// The background colour DiffLine paints for [line] (null = no tint).
Future<Color?> tintOf(WidgetTester tester, String line) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: DiffLine(line: line))));
  return tester.widget<Container>(find.byType(Container)).color;
}

void main() {
  testWidgets('added and removed lines are tinted differently', (tester) async {
    final added = await tintOf(tester, '+two');
    final removed = await tintOf(tester, '-one');
    expect(added, isNotNull);
    expect(removed, isNotNull);
    expect(added, isNot(removed));
  });

  testWidgets('context, hunk headers and metadata carry no tint', (tester) async {
    expect(await tintOf(tester, ' unchanged'), isNull);
    expect(await tintOf(tester, '@@ -1,1 +1,1 @@'), isNull);
    expect(await tintOf(tester, '… +12 lines truncated'), isNull);
    // Real Edit diffs end with this marker; it is metadata, not an added line.
    expect(await tintOf(tester, r'\ No newline at end of file'), isNull);
  });
}
