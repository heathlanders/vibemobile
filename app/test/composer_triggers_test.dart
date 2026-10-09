import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/composer_triggers.dart';

void main() {
  test('bare slash at start of text triggers with an empty query', () {
    final t = detectSlash('/', 1);
    expect(t, isNotNull);
    expect(t!.query, '');
    expect(t.start, 0);
    expect(t.end, 1);
  });

  test('command and argument split', () {
    final t = detectSlash('/prompt code review', 19)!;
    expect(t.command, 'prompt');
    expect(t.argument, 'code review');
  });

  test('command with no argument has an empty argument', () {
    expect(detectSlash('/files', 6)!.argument, '');
  });

  test('slash mid-line does not trigger (paths, urls)', () {
    expect(detectSlash('open lib/core', 13), isNull);
    expect(detectSlash('see https://x.dev/y', 19), isNull);
  });

  test('slash at the start of a later line triggers', () {
    final t = detectSlash('hello\n/files', 12);
    expect(t, isNotNull);
    expect(t!.command, 'files');
    expect(t.start, 6);
  });

  test('a newline after the slash ends the trigger', () {
    expect(detectSlash('/files\nnow what', 15), isNull);
  });

  test('caret before the slash does not trigger', () {
    expect(detectSlash('/files', 0), isNull);
  });

  test('out-of-range caret is ignored', () {
    expect(detectSlash('/files', 99), isNull);
    expect(detectSlash('/files', -1), isNull);
  });

  // ---- @file mentions -----------------------------------------------------

  test('mention at start of text triggers', () {
    final m = detectMention('@lib/th', 7)!;
    expect(m.query, 'lib/th');
    expect(m.start, 0);
    expect(m.end, 7);
  });

  test('mention after whitespace triggers', () {
    final m = detectMention('look at @core/theme.dart', 24)!;
    expect(m.query, 'core/theme.dart');
    expect(m.start, 8);
  });

  test('mid-word @ does not trigger (emails, user@host)', () {
    expect(detectMention('mail me@example.com', 19), isNull);
  });

  test('whitespace ends the mention', () {
    expect(detectMention('@lib/a.dart now', 15), isNull);
    expect(detectMention('@lib/a.dart\n', 12), isNull);
  });

  test('a slash trigger wins over a stale @ earlier in the text', () {
    // Both patterns are present; the screen prefers the slash under the caret.
    expect(detectSlash('@lib/x\n/files', 13), isNotNull);
  });
}
