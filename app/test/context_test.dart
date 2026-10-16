import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/domain/context_usage.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/chat/presentation/context_sheet.dart';

ChatSessionController controller() => ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

Map<String, dynamic> frame({int tokens = 26321, int max = 1000000, int percent = 3, int? autoAt = 967000, List<Map<String, dynamic>>? cats}) => {
      't': 'context',
      'tokens': tokens,
      'max': max,
      'percent': percent,
      'autoCompactAt': autoAt,
      'categories': cats ??
          [
            {'name': 'System tools', 'tokens': 8835},
            {'name': 'Messages', 'tokens': 7138},
          ],
      'model': 'claude-sonnet-5-5',
    };

void main() {
  group('tokenLabel', () {
    test('plain, k and M', () {
      expect(tokenLabel(0), '0');
      expect(tokenLabel(950), '950');
      expect(tokenLabel(1000), '1k');
      expect(tokenLabel(26321), '26k');
      expect(tokenLabel(967000), '967k');
      expect(tokenLabel(1000000), '1M');
      expect(tokenLabel(1500000), '1.5M');
    });
  });

  group('ContextUsage', () {
    test('parses the daemon frame; label reads like a status line', () {
      final u = ContextUsage.fromFrame(frame());
      expect([u.tokens, u.max, u.percent, u.autoCompactAt, u.model], [26321, 1000000, 3, 967000, 'claude-sonnet-5-5']);
      expect(u.categories.map((c) => c.name), ['System tools', 'Messages']);
      expect(u.label, '26k / 1M · 3%');
    });

    test('memory files: parsed, friendly kind labels, junk skipped', () {
      final u = ContextUsage.fromFrame({
        'memoryFiles': [
          {'path': '/a/CLAUDE.md', 'type': 'Project', 'tokens': 10},
          {'path': '/b/.claude/CLAUDE.md', 'type': 'User', 'tokens': 5},
          {'path': '/c/x.md', 'type': 'Weird', 'tokens': 1},
          {'path': 7},
          null,
        ],
        'rules': 'yes',
      });
      expect(u.memoryFiles.map((m) => m.kind), ['Project instructions', 'Your global instructions', 'Weird']);
      expect(u.memoryFiles.first.fileName, 'CLAUDE.md');
      expect(u.rulesApplied, isNull, reason: 'a non-bool is "unknown", not false');
    });

    test('ruleNames: strings kept, junk skipped, absent = empty', () {
      final u = ContextUsage.fromFrame({'rules': true, 'ruleNames': ['Storage rules', 3, 'Ambition (Rieseberg)']});
      expect(u.ruleNames, ['Storage rules', 'Ambition (Rieseberg)']);
      expect(ContextUsage.fromFrame({'rules': true}).ruleNames, isEmpty);
    });

    test('tolerates a bare/odd frame (never throws)', () {
      final u = ContextUsage.fromFrame({'t': 'context', 'categories': 'nope'});
      expect([u.tokens, u.max, u.percent, u.categories], [0, 0, 0, isEmpty]);
      // wrong types in every field
      final w = ContextUsage.fromFrame({'tokens': '5', 'max': [], 'percent': {}, 'autoCompactAt': 'x', 'categories': [null, 3, {'name': 1, 'tokens': 'y'}], 'model': 7});
      expect([w.tokens, w.max, w.percent, w.autoCompactAt, w.model], [0, 0, 0, null, null]);
      expect(w.categories.length, 1);
      expect(u.fraction, 0);
      expect(u.high, false);
    });

    test('fraction clamps; "high" is measured against the auto-compaction point when there is one', () {
      expect(ContextUsage.fromFrame(frame(tokens: 2000000)).fraction, 1.0);
      // 80% of the 967k compaction point is "high" even though the window is only 77% full.
      final nearCompact = ContextUsage.fromFrame(frame(tokens: 780000, autoAt: 967000));
      expect(nearCompact.high, true);
      expect(nearCompact.fraction < 0.8, true);
      expect(ContextUsage.fromFrame(frame(tokens: 700000, autoAt: 967000)).high, false);
      // no auto-compaction: falls back to the window itself
      expect(ContextUsage.fromFrame(frame(tokens: 850000, autoAt: null)).high, true);
      expect(ContextUsage.fromFrame(frame(tokens: 100000, autoAt: null)).high, false);
    });
  });

  group('controller', () {
    test('a context frame sets the reading; none until then', () {
      final c = controller();
      expect(c.context, isNull);
      c.applyFrame(frame());
      expect(c.context!.tokens, 26321);
      c.applyFrame(frame(tokens: 3000));
      expect(c.context!.tokens, 3000);
    });

    test('a compacted frame appends a notice row (and is not an assistant message)', () {
      final c = controller();
      c.applyFrame({'t': 'assistant', 'text': 'hello'});
      c.applyFrame({'t': 'compacted', 'text': 'Context compacted (manual): 24,261 → 2,806 tokens', 'trigger': 'manual'});
      expect(c.messages.map((m) => m.role), [ChatRole.assistant, ChatRole.notice]);
      expect(c.messages.last.text, contains('24,261 → 2,806'));
    });

    test('history replays a stored notice in order — once', () {
      final c = controller();
      c.applyFrame({
        't': 'history',
        'messages': [
          {'id': 'a', 'role': 'user', 'content': 'q', 'ts': '1'},
          {'id': 'b', 'role': 'notice', 'content': 'Context compacted (auto)', 'ts': '2'},
          {'id': 'c', 'role': 'assistant', 'content': 'a', 'ts': '3'},
        ],
      });
      expect(c.messages.map((m) => m.role), [ChatRole.user, ChatRole.notice, ChatRole.assistant]);
    });

    test('compact() with no socket is a harmless no-op', () {
      expect(() => controller().compact(), returnsNormally);
    });

    test('a notice survives the offline cache round-trip', () {
      final m = ChatMessage(role: ChatRole.notice, text: 'x');
      expect(ChatMessage.fromJson(m.toJson()).role, ChatRole.notice);
    });
  });

  group('ContextStrip', () {
    testWidgets('shows the label, a progress bar relative to the compaction point, and is tappable', (t) async {
      var taps = 0;
      final u = ContextUsage.fromFrame(frame(tokens: 483500, autoAt: 967000, percent: 48));
      await t.pumpWidget(MaterialApp(home: Scaffold(body: ContextStrip(usage: u, onTap: () => taps++))));
      expect(find.text('Context 484k / 1M · 48%'), findsOneWidget);
      expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.5, 0.001));
      await t.tap(find.byType(InkWell));
      expect(taps, 1);
    });
  });

  group('ContextSheet', () {
    Future<void> open(WidgetTester t, {VoidCallback? onCompact, ContextUsage? usage}) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showContextSheet(ctx, usage: usage ?? ContextUsage.fromFrame(frame()), onCompact: onCompact),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('lists the breakdown and where auto-compaction happens', (t) async {
      await open(t, onCompact: () {});
      expect(find.text('Context window'), findsOneWidget);
      expect(find.textContaining('26k of 1M tokens used (3%)'), findsOneWidget);
      expect(find.text('System tools'), findsOneWidget);
      expect(find.text('9k'), findsOneWidget); // 8835
      expect(find.textContaining('automatically at 967k'), findsOneWidget);
    });

    testWidgets('shows which instruction files are loaded and whether the server rules applied', (t) async {
      final u = ContextUsage.fromFrame({
        ...frame(),
        'memoryFiles': [
          {'path': '/home/user/vibemobile/CLAUDE.md', 'type': 'Project', 'tokens': 1489},
          {'path': '/home/user/.claude/projects/x/memory/MEMORY.md', 'type': 'AutoMem', 'tokens': 344},
        ],
        'rules': true,
      });
      await open(t, onCompact: () {}, usage: u);
      expect(find.text('Instructions in force'), findsOneWidget);
      expect(find.text('CLAUDE.md · Project instructions'), findsOneWidget);
      expect(find.text('MEMORY.md · Auto memory'), findsOneWidget);
      expect(find.text('1k'), findsOneWidget);
      expect(find.text('Server storage rules: applied to this chat'), findsOneWidget);
    });

    testWidgets('says plainly when nothing is loaded, and when the server rules were not applied', (t) async {
      await open(t, onCompact: () {}, usage: ContextUsage.fromFrame({...frame(), 'rules': false}));
      expect(find.text('No CLAUDE.md or memory file was loaded for this session.'), findsOneWidget);
      expect(find.textContaining('not applied'), findsOneWidget);
    });

    testWidgets('an old daemon (no rules field) makes no claim about the server rules', (t) async {
      await open(t, onCompact: () {});
      expect(find.textContaining('Server storage rules'), findsNothing);
    });

    testWidgets('says so when auto-compaction is off', (t) async {
      await open(t, onCompact: () {}, usage: ContextUsage.fromFrame(frame(autoAt: null)));
      expect(find.text('Automatic compaction is off.'), findsOneWidget);
    });

    testWidgets('Compact now calls back and closes the sheet', (t) async {
      var called = 0;
      await open(t, onCompact: () => called++);
      await t.tap(find.text('Compact now'));
      await t.pumpAndSettle();
      expect(called, 1);
      expect(find.text('Context window'), findsNothing);
    });

    testWidgets('while a reply is running the button is disabled and explains why', (t) async {
      await open(t, onCompact: null);
      expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(find.textContaining('Wait for the current reply'), findsOneWidget);
    });
  });
}
