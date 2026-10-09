import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/chat/presentation/effort_sheet.dart';

ChatSessionController controller() => ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');
const levels = ['low', 'medium', 'high', 'xhigh', 'max'];

void main() {
  group('controller', () {
    test('hidden until the daemon says which levels exist (native engine / old daemon never send it)', () {
      final c = controller();
      expect(c.effortLevels, isEmpty);
      expect(c.effort, isNull);
    });

    test('an effort frame sets the level and the available levels; null = model default', () {
      final c = controller();
      c.applyFrame({'t': 'effort', 'effort': 'high', 'levels': levels});
      expect([c.effort, c.effortLevels], ['high', levels]);
      c.applyFrame({'t': 'effort', 'effort': null, 'levels': levels});
      expect(c.effort, isNull);
      expect(c.effortLevels, levels);
    });
  });

  group('EffortSheet', () {
    Future<String?> open(WidgetTester t, {String? current}) async {
      String? result = 'unset';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => result = await showEffortSheet(ctx, current: current, levels: levels),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return Future.value(result);
    }

    testWidgets('lists Default plus every level with a plain-words hint', (t) async {
      await open(t);
      expect(find.text('Default'), findsOneWidget);
      for (final l in ['Low', 'Medium', 'High', 'Xhigh', 'Max']) {
        expect(find.text(l), findsOneWidget, reason: l);
      }
      expect(find.text(effortHints['max']!), findsOneWidget);
      expect(find.textContaining('next message'), findsOneWidget);
    });

    testWidgets('the current level is marked; Default is marked when none is set', (t) async {
      await open(t, current: 'high');
      ListTile tile(String title) => t.widget<ListTile>(find.widgetWithText(ListTile, title));
      expect(tile('High').selected, true);
      expect(tile('Low').selected, false);
      expect(tile('Default').selected, false);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await open(t);
      expect(t.widget<ListTile>(find.widgetWithText(ListTile, 'Default')).selected, true);
    });

    testWidgets('tapping a level closes the sheet with it; Default closes with the empty string', (t) async {
      String? got = 'unset';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(onPressed: () async => got = await showEffortSheet(ctx, current: 'low', levels: levels), child: const Text('open')),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Max'));
      await t.pumpAndSettle();
      expect(got, 'max');
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Default'));
      await t.pumpAndSettle();
      expect(got, '');
    });
  });
}
