import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/session_attention.dart';

void main() {
  test('raise/clear per session; a blocking prompt is never downgraded to done', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(sessionAttentionProvider.notifier);

    n.raise('a', Attention.done);
    n.raise('b', Attention.needsInput);
    expect(c.read(sessionAttentionProvider), {'a': Attention.done, 'b': Attention.needsInput});

    n.raise('a', Attention.needsInput); // upgrade
    n.raise('b', Attention.done); // no downgrade
    expect(c.read(sessionAttentionProvider), {'a': Attention.needsInput, 'b': Attention.needsInput});

    n.clear('a');
    n.clear('missing'); // no-op
    expect(c.read(sessionAttentionProvider).keys, ['b']);
  });

  testWidgets('FlashingBadge: nothing at 0, red count when flagged, steady with reduce-motion', (t) async {
    Widget host(int count, {bool reduce = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: Scaffold(body: Center(child: FlashingBadge(count: count, child: const Icon(Icons.home)))),
          ),
        );

    await t.pumpWidget(host(0));
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsNothing);

    await t.pumpWidget(host(2));
    expect(find.text('2'), findsOneWidget);
    final fade = t.widget<FadeTransition>(find.descendant(of: find.byType(FlashingBadge), matching: find.byType(FadeTransition)));
    final first = fade.opacity.value;
    await t.pump(const Duration(milliseconds: 350));
    expect(fade.opacity.value, isNot(first), reason: 'pulses');

    await t.pumpWidget(host(2, reduce: true));
    await t.pump(const Duration(milliseconds: 350));
    expect(find.text('2'), findsOneWidget, reason: 'still shown');
    expect(find.descendant(of: find.byType(FlashingBadge), matching: find.byType(FadeTransition)), findsNothing,
        reason: 'but not pulsing');

    await t.pumpWidget(host(0)); // stops the repeating controller before teardown
  });
}
