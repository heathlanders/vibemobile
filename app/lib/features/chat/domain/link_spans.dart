/// A run of chat text: plain, or an http(s) link (proposal 34).
class LinkSegment {
  const LinkSegment(this.text, {this.isLink = false});
  final String text;
  final bool isLink;

  @override
  bool operator ==(Object other) => other is LinkSegment && other.text == text && other.isLink == isLink;
  @override
  int get hashCode => Object.hash(text, isLink);
  @override
  String toString() => 'LinkSegment($text, link: $isLink)';
}

final _urlRe = RegExp(r'https?://[^\s<>"`]+', caseSensitive: false);
const _trailing = '.,;:!?\'"]}';

/// Splits [text] into plain and http(s)-link segments. Trailing punctuation is
/// not part of the link; a closing `)` stays only if the URL has a matching `(`.
/// Other schemes (ftp, javascript, …) are never linkified.
List<LinkSegment> splitLinks(String text) {
  final out = <LinkSegment>[];
  var last = 0;
  for (final m in _urlRe.allMatches(text)) {
    var url = m.group(0)!;
    while (url.isNotEmpty) {
      final c = url[url.length - 1];
      if (_trailing.contains(c) || (c == ')' && _count(url, '(') < _count(url, ')'))) {
        url = url.substring(0, url.length - 1);
      } else {
        break;
      }
    }
    if (!RegExp(r'^https?://.', caseSensitive: false).hasMatch(url)) continue;
    if (m.start > last) out.add(LinkSegment(text.substring(last, m.start)));
    out.add(LinkSegment(url, isLink: true));
    last = m.start + url.length;
  }
  if (last < text.length) out.add(LinkSegment(text.substring(last)));
  return out;
}

int _count(String s, String ch) => ch.allMatches(s).length;
