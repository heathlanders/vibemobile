import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/link_spans.dart';

void main() {
  List<String> links(String t) => [for (final s in splitLinks(t)) if (s.isLink) s.text];

  test('plain text is one segment', () {
    expect(splitLinks('hello'), [const LinkSegment('hello')]);
  });
  test('url in sentence, trailing punctuation trimmed', () {
    expect(splitLinks('see https://a.com/x. ok'), [
      const LinkSegment('see '),
      const LinkSegment('https://a.com/x', isLink: true),
      const LinkSegment('. ok'),
    ]);
  });
  test('parens', () {
    expect(links('(https://a.com/b)'), ['https://a.com/b']);
    expect(links('https://en.wikipedia.org/wiki/X_(y)'), ['https://en.wikipedia.org/wiki/X_(y)']);
  });
  test('multiple + query', () {
    expect(links('https://a.com/?q=1&b=2, http://b.org'), ['https://a.com/?q=1&b=2', 'http://b.org']);
  });
  test('other schemes ignored', () {
    expect(links('ftp://a.com javascript:alert(1) https://'), isEmpty);
  });
}
