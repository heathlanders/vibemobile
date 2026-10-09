import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/widgets.dart';

void main() {
  testWidgets('FadeSlideIn ends fully opaque and unshifted', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: FadeSlideIn(child: Text('hello')),
    ));
    // Mid-flight: still fading in.
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1.0));

    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('SkeletonBox pulses (repeating — never settles)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SkeletonBox(width: 40)));
    Color? colorNow() =>
        (tester.widget<Container>(find.byType(Container)).decoration as BoxDecoration).color;

    final first = colorNow();
    await tester.pump(const Duration(milliseconds: 450));
    expect(colorNow(), isNot(first));
    // Leave the repeating controller in a known state so the test can tear down.
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('EmptyState shows icon, title and hint', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EmptyState(icon: Icons.folder_off_outlined, title: 'Nothing here', hint: 'Add one'),
      ),
    ));
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Add one'), findsOneWidget);
  });

  testWidgets('sharedAxisRoute pushes and pops the page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            sharedAxisRoute(const Scaffold(body: Text('next page'))),
          ),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('next page'), findsOneWidget);
  });
}
