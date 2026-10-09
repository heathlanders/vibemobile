import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/pairing/presentation/pairing_screen.dart';

void main() {
  testWidgets('pairing screen shows its fields and validates empties', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: PairingScreen()),
      ),
    );

    expect(find.text('Daemon URL'), findsOneWidget);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.text('Device name'), findsOneWidget);

    // Tapping Pair with an empty code surfaces the validation error.
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    expect(find.text('All fields are required.'), findsOneWidget);
  });
}
