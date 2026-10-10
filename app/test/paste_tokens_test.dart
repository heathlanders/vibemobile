import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/paste_tokens.dart';

String lines(int n) => List.generate(n, (i) => 'line $i').join('\n');

TextEditingValue v(String t) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));

void main() {
  test('threshold edges: 10 lines / 1000 chars stay, 11 lines / 1001 chars collapse', () {
    expect(PasteTokens.isLarge(lines(10)), isFalse);
    expect(PasteTokens.isLarge(lines(11)), isTrue);
    expect(PasteTokens.isLarge('x' * 1000), isFalse);
    expect(PasteTokens.isLarge('x' * 1001), isTrue);
  });

  test('small insertion is untouched; large one becomes a token and round-trips', () {
    final t = PasteTokens();
    expect(t.collapse(v(''), v('hello')).text, 'hello');
    final text = lines(42);
    final out = t.collapse(v('see: '), v('see: $text'));
    expect(out.text, 'see: [Pasted text #1 +42 lines]');
    expect(out.selection.baseOffset, out.text.length);
    expect(t.expand(out.text), 'see: $text');
  });

  test('insertion in the middle keeps surrounding text and caret after the token', () {
    final t = PasteTokens();
    final text = 'y' * 1500;
    final out = t.insert(const TextEditingValue(text: 'ab', selection: TextSelection.collapsed(offset: 1)), text);
    expect(out.text, 'a[Pasted text #1 +1 lines]b');
    expect(out.selection.baseOffset, 'a[Pasted text #1 +1 lines]'.length);
    expect(t.expand(out.text), 'a${text}b');
  });

  test('multiple pastes number up; clear restarts at #1', () {
    final t = PasteTokens();
    final a = t.collapse(v(''), v(lines(20)));
    final b = t.collapse(a, v('${a.text} and ${lines(30)}'));
    expect(b.text, contains('#1 +20 lines'));
    expect(b.text, contains('#2 +30 lines'));
    expect(t.expand(b.text), '${lines(20)} and ${lines(30)}');
    t.clear();
    expect(t.pastes, isEmpty);
    expect(t.collapse(v(''), v(lines(12))).text, '[Pasted text #1 +12 lines]');
  });

  test('an edited token stays literal; forget drops the entry', () {
    final t = PasteTokens();
    final tok = t.add(lines(15));
    final edited = tok.replaceFirst('+15', '+16');
    expect(t.expand(edited), edited);
    expect(t.expand('x $tok'), 'x ${lines(15)}');
    t.forget(tok);
    expect(t.pastes, isEmpty);
    expect(t.expand(tok), tok); // unknown token → literal
  });

  test('formatter collapses a large edit', () {
    final t = PasteTokens();
    final out = PasteCollapseFormatter(t).formatEditUpdate(v(''), v(lines(11)));
    expect(out.text, '[Pasted text #1 +11 lines]');
  });
}
