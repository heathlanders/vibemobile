import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';
import 'package:vibemobile/features/terminal/presentation/terminal_screen.dart';

// TerminalScreen against an unreachable daemon (port 1): it never goes live, so
// it sits in connecting/reconnecting. pumpAndSettle never settles (spinner).
void main() {
  const session = Session(id: 's1', projectId: 'p1', kind: 'shell', status: 'live', createdAt: '2026-01-01T00:00:00Z', title: 'my shell');
  const creds = Creds('http://127.0.0.1:1', 't');

  Future<void> pump(WidgetTester tester, {VoidCallback? onClose, Uri? url}) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: TerminalScreen(creds: creds, session: session, url: url, onClose: onClose),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
  }

  // Dispose the screen so the controller cancels its reconnect timer.
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('renders the title and a connecting/reconnecting banner when unreachable', (tester) async {
    await pump(tester);
    expect(find.text('my shell'), findsOneWidget);
    expect(find.textContaining(RegExp('Connecting…|Reconnecting…')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    expect(find.byTooltip('Close session'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('closing asks first; Cancel keeps the session, End closes it', (tester) async {
    var closed = 0;
    await pump(tester, onClose: () => closed++);

    await tester.tap(find.byTooltip('Close session'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('End session?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('End session?'), findsNothing);
    expect(closed, 0, reason: 'cancel leaves the session running');

    await tester.tap(find.byTooltip('Close session'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'End'));
      await Future<void>.delayed(const Duration(milliseconds: 200)); // DELETE (stubbed) completes
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(closed, 1);
    await teardown(tester);
  });

  testWidgets('a CLI tty view (url set) has no close button', (tester) async {
    await pump(tester, url: Uri.parse('ws://127.0.0.1:1/tty/s1'));
    expect(find.text('my shell'), findsOneWidget);
    expect(find.byTooltip('Close session'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
    await teardown(tester);
  });
}
