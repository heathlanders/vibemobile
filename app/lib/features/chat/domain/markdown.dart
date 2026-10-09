// A small, dependency-free markdown subset for chat messages. Pure Dart so it is
// unit-testable and cheap to re-run on every streamed delta.
//
// Supported: fenced code, headings, bullet/numbered lists (nested by indent), block
// quotes, horizontal rules, GFM-style tables, paragraphs; inline `code`, **bold**,
// *italic*, ***both***, [text](http(s) url), \escapes. Anything unclosed stays literal,
// so a half-streamed message never throws or flickers into something else — except an
// unterminated ``` fence, which is deliberately shown as a (still open) code block.
//
// Not supported on purpose: raw HTML (never interpreted — shown as text), images,
// reference links, footnotes, setext headings.

import 'link_spans.dart';

sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdCode extends MdBlock {
  const MdCode(this.code, {this.lang = '', this.closed = true});
  final String code;
  final String lang;

  /// False while the closing fence hasn't streamed in yet.
  final bool closed;
}

class MdListItem extends MdBlock {
  const MdListItem(this.text, {required this.depth, this.number});
  final String text;
  final int depth;

  /// Null for a bullet; the item's own number for an ordered list.
  final int? number;
}

class MdQuote extends MdBlock {
  const MdQuote(this.text);
  final String text;
}

class MdRule extends MdBlock {
  const MdRule();
}

class MdTable extends MdBlock {
  const MdTable(this.header, this.rows);
  final List<String> header;
  final List<List<String>> rows;
}

final _fence = RegExp(r'^ {0,3}(```+|~~~+)\s*([^\s`]*)');
final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _rule = RegExp(r'^ {0,3}([-*_])(\s*\1){2,}\s*$');
final _item = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$');
final _quote = RegExp(r'^ {0,3}>\s?(.*)$');
final _tableSep = RegExp(r'^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$');

List<String> _cells(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  return s.split(RegExp(r'(?<!\\)\|')).map((c) => c.trim().replaceAll(r'\|', '|')).toList();
}

bool _isTableStart(List<String> lines, int i) =>
    i + 1 < lines.length && lines[i].contains('|') && _tableSep.hasMatch(lines[i + 1]) && lines[i + 1].contains('-');

List<MdBlock> parseMarkdown(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final out = <MdBlock>[];
  final para = <String>[];

  void flush() {
    if (para.isEmpty) return;
    out.add(MdParagraph(para.join('\n')));
    para.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    final f = _fence.firstMatch(line);
    if (f != null) {
      flush();
      final marker = f.group(1)!;
      final body = <String>[];
      var closed = false;
      i++;
      while (i < lines.length) {
        if (RegExp('^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}\\s*\$').hasMatch(lines[i])) {
          closed = true;
          i++;
          break;
        }
        body.add(lines[i]);
        i++;
      }
      out.add(MdCode(body.join('\n'), lang: f.group(2) ?? '', closed: closed));
      continue;
    }

    if (line.trim().isEmpty) {
      flush();
      i++;
      continue;
    }

    final h = _heading.firstMatch(line);
    if (h != null) {
      flush();
      out.add(MdHeading(h.group(1)!.length, h.group(2)!));
      i++;
      continue;
    }

    if (_rule.hasMatch(line)) {
      flush();
      out.add(const MdRule());
      i++;
      continue;
    }

    if (_isTableStart(lines, i)) {
      flush();
      final header = _cells(lines[i]);
      i += 2;
      final rows = <List<String>>[];
      while (i < lines.length && lines[i].contains('|') && lines[i].trim().isNotEmpty) {
        rows.add(_cells(lines[i]));
        i++;
      }
      out.add(MdTable(header, rows));
      continue;
    }

    final q = _quote.firstMatch(line);
    if (q != null) {
      flush();
      final body = <String>[];
      while (i < lines.length) {
        final m = _quote.firstMatch(lines[i]);
        if (m == null) break;
        body.add(m.group(1)!);
        i++;
      }
      out.add(MdQuote(body.join('\n')));
      continue;
    }

    final it = _item.firstMatch(line);
    if (it != null) {
      flush();
      final marker = it.group(2)!;
      final number = RegExp(r'^\d').hasMatch(marker) ? int.tryParse(marker.replaceAll(RegExp(r'\D'), '')) : null;
      var text = it.group(3)!;
      final depth = (it.group(1)!.replaceAll('\t', '    ').length ~/ 2).clamp(0, 6);
      i++;
      // Indented continuation lines belong to this item.
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          RegExp(r'^\s{2,}\S').hasMatch(lines[i]) &&
          !_item.hasMatch(lines[i]) &&
          !_fence.hasMatch(lines[i])) {
        text += '\n${lines[i].trim()}';
        i++;
      }
      out.add(MdListItem(text, depth: depth, number: number));
      continue;
    }

    para.add(line);
    i++;
  }
  flush();
  return out;
}

// ---- inline ----------------------------------------------------------------------

class MdInline {
  const MdInline(this.text, {this.bold = false, this.italic = false, this.code = false, this.url});
  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// Set for links: `[label](url)` or a bare http(s) URL.
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is MdInline && other.text == text && other.bold == bold && other.italic == italic && other.code == code && other.url == url;
  @override
  int get hashCode => Object.hash(text, bold, italic, code, url);
  @override
  String toString() => 'MdInline($text${bold ? ' b' : ''}${italic ? ' i' : ''}${code ? ' c' : ''}${url != null ? ' ->$url' : ''})';
}

bool _alnum(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);

/// Inline markdown -> styled runs. Adjacent runs with identical style are merged.
List<MdInline> parseInline(String s) {
  final out = <MdInline>[];
  _inline(s, out, false, false);
  final merged = <MdInline>[];
  for (final r in out) {
    if (r.text.isEmpty) continue;
    final last = merged.isEmpty ? null : merged.last;
    if (last != null && last.url == null && r.url == null && last.bold == r.bold && last.italic == r.italic && last.code == r.code) {
      merged[merged.length - 1] = MdInline(last.text + r.text, bold: r.bold, italic: r.italic, code: r.code);
    } else {
      merged.add(r);
    }
  }
  return merged;
}

void _plain(String text, List<MdInline> out, bool bold, bool italic) {
  if (text.isEmpty) return;
  for (final seg in splitLinks(text)) {
    out.add(MdInline(seg.text, bold: bold, italic: italic, url: seg.isLink ? seg.text : null));
  }
}

void _inline(String s, List<MdInline> out, bool bold, bool italic) {
  final buf = StringBuffer();
  void emit() {
    _plain(buf.toString(), out, bold, italic);
    buf.clear();
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];

    if (c == r'\' && i + 1 < s.length && '\\`*_{}[]()#+-.!|>~'.contains(s[i + 1])) {
      buf.write(s[i + 1]);
      i += 2;
      continue;
    }

    if (c == '`') {
      var n = 1;
      while (i + n < s.length && s[i + n] == '`') {
        n++;
      }
      final tick = '`' * n;
      final end = s.indexOf(tick, i + n);
      if (end > i + n) {
        emit();
        var code = s.substring(i + n, end);
        if (code.length > 1 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
          code = code.substring(1, code.length - 1);
        }
        out.add(MdInline(code, bold: bold, italic: italic, code: true));
        i = end + n;
        continue;
      }
      buf.write(tick);
      i += n;
      continue;
    }

    if (c == '[') {
      final close = s.indexOf('](', i + 1);
      if (close > i + 1 && !s.substring(i + 1, close).contains('\n')) {
        final end = s.indexOf(')', close + 2);
        if (end > close) {
          final url = s.substring(close + 2, end).trim();
          if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(url)) {
            emit();
            final label = s.substring(i + 1, close);
            final inner = <MdInline>[];
            _inline(label, inner, bold, italic);
            for (final r in inner) {
              out.add(MdInline(r.text, bold: r.bold, italic: r.italic, code: r.code, url: url));
            }
            i = end + 1;
            continue;
          }
        }
      }
    }

    if (c == '*' || c == '_') {
      var n = 1;
      while (i + n < s.length && s[i + n] == c) {
        n++;
      }
      final run = n >= 3 ? 3 : n; // ***x*** / **x** / *x*
      if (n <= 3) {
        final token = c * run;
        final before = i == 0 ? ' ' : s[i - 1];
        final after = i + n < s.length ? s[i + n] : ' ';
        // `_` only at word edges (snake_case stays literal); opener can't be followed by a space.
        final canOpen = after.trim().isNotEmpty && !(c == '_' && _alnum(before));
        if (canOpen) {
          var end = s.indexOf(token, i + n);
          while (end != -1) {
            final prev = s[end - 1];
            final next = end + n < s.length ? s[end + n] : ' ';
            final exact = end + run >= s.length || s[end + run] != c;
            if (prev.trim().isNotEmpty && exact && !(c == '_' && _alnum(next))) break;
            end = s.indexOf(token, end + 1);
          }
          if (end > i + n) {
            emit();
            _inline(s.substring(i + n, end), out, bold || run >= 2, italic || run == 1 || run == 3);
            i = end + n;
            continue;
          }
        }
      }
      buf.write(c * n);
      i += n;
      continue;
    }

    buf.write(c);
    i++;
  }
  emit();
}
