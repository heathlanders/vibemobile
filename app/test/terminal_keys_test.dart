import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/terminal/domain/ctrl_latch.dart';
import 'package:vibemobile/features/terminal/presentation/terminal_key_row.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('CtrlLatch', () {
    test('passes everything through while disarmed', () {
      final c = CtrlLatch();
      expect(c.take('c'), 'c');
      expect(c.take('hello'), 'hello');
    });

    test('armed: letters become control codes, then it disarms', () {
      final c = CtrlLatch()..toggle();
      expect(c.armed, true);
      expect(c.take('c').codeUnits, [3]); // Ctrl+C
      expect(c.armed, false, reason: 'one-shot');
      expect(c.take('c'), 'c');
    });

    test('upper-case and the classic punctuation controls', () {
      for (final (input, code) in [('D', 4), ('l', 12), ('Z', 26), ('[', 27), ('\\', 28), (']', 29), ('^', 30), ('_', 31), ('@', 0), (' ', 0)]) {
        final c = CtrlLatch()..toggle();
        expect(c.take(input).codeUnits, [code], reason: 'Ctrl+$input');
      }
    });

    test('digits, multi-char input and escape sequences pass through but still disarm', () {
      for (final s in ['5', 'paste me', '\x1b[A']) {
        final c = CtrlLatch()..toggle();
        expect(c.take(s), s);
        expect(c.armed, false, reason: s);
      }
    });

    test('toggle twice disarms; clear is idempotent and notifies only on change', () {
      final c = CtrlLatch();
      var n = 0;
      c.addListener(() => n++);
      c.clear();
      expect(n, 0);
      c.toggle();
      c.toggle();
      expect(c.armed, false);
      expect(n, 2);
    });
  });

  group('TerminalKeyRow', () {
    late Terminal terminal;
    late CtrlLatch ctrl;
    late List<String> sent;

    Future<void> pump(WidgetTester t) async {
      terminal = Terminal();
      ctrl = CtrlLatch();
      sent = [];
      terminal.onOutput = (d) => sent.add(ctrl.take(d));
      await t.pumpWidget(MaterialApp(home: Scaffold(body: TerminalKeyRow(terminal: terminal, ctrl: ctrl))));
    }

    testWidgets('Esc, Tab and arrows send the real terminal sequences', (t) async {
      await pump(t);
      await t.tap(find.text('Esc'));
      await t.tap(find.text('Tab'));
      await t.tap(find.text('↑'));
      await t.tap(find.text('←'));
      expect(sent, ['\x1b', '\t', '\x1b[A', '\x1b[D']);
    });

    testWidgets('punctuation keys type their character', (t) async {
      await pump(t);
      await t.tap(find.text('|'));
      await t.tap(find.text('~'));
      expect(sent, ['|', '~']);
    });

    testWidgets('Ctrl is sticky until the next key, then the soft-keyboard letter becomes a control code', (t) async {
      await pump(t);
      await t.tap(find.byKey(const Key('ctrl')));
      await t.pump();
      expect(ctrl.armed, true);
      terminal.textInput('c'); // what the phone keyboard produces
      expect(sent.last.codeUnits, [3]);
      expect(ctrl.armed, false);
    });

    testWidgets('Ctrl + a row key combines (Ctrl+Left) and disarms', (t) async {
      await pump(t);
      await t.tap(find.byKey(const Key('ctrl')));
      await t.tap(find.text('←'));
      expect(sent.single, isNot('\x1b[D'), reason: 'modified, not the plain arrow');
      expect(sent.single, startsWith('\x1b['));
      expect(ctrl.armed, false);
    });
  });
}
