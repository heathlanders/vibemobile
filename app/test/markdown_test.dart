import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/markdown.dart';
import 'package:vibemobile/features/chat/presentation/markdown_text.dart';

T only<T extends MdBlock>(String md) {
  final b = parseMarkdown(md);
  expect(b.length, 1, reason: '$b');
  return b.single as T;
}

List<MdInline> inl(String s) => parseInline(s);

void main() {
  group('blocks', () {
    test('plain text is one paragraph; soft line breaks are kept', () {
      expect(only<MdParagraph>('hello\nworld').text, 'hello\nworld');
    });

    test('blank line splits paragraphs', () {
      final b = parseMarkdown('one\n\ntwo');
      expect(b.map((e) => (e as MdParagraph).text), ['one', 'two']);
    });

    test('fenced code keeps content verbatim, with lang', () {
      final c = only<MdCode>('```dart\nvoid main() {\n  print("**not bold**");\n}\n```');
      expect(c.lang, 'dart');
      expect(c.code, 'void main() {\n  print("**not bold**");\n}');
      expect(c.closed, true);
    });

    test('an unterminated fence (mid-stream) is an open code block, not a paragraph', () {
      final c = only<MdCode>('```py\nprint(1)\nprint(');
      expect(c.closed, false);
      expect(c.code, 'print(1)\nprint(');
    });

    test('longer fences and ~~~ work; a shorter inner fence does not close', () {
      final c = only<MdCode>('````\n```\ninner\n```\n````');
      expect(c.code, '```\ninner\n```');
      expect(only<MdCode>('~~~\nx\n~~~').code, 'x');
    });

    test('markdown syntax inside code is never interpreted', () {
      final b = parseMarkdown('```\n# not a heading\n- not a list\n```');
      expect(b.single, isA<MdCode>());
    });

    test('headings', () {
      final h = only<MdHeading>('## Title ##');
      expect([h.level, h.text], [2, 'Title']);
      expect(only<MdParagraph>('#nospace').text, '#nospace');
      expect(only<MdParagraph>('####### seven').text, '####### seven');
    });

    test('bullets and numbers, nested by indent, numbers preserved', () {
      final b = parseMarkdown('- a\n  - b\n3. c\n4) d');
      final items = b.cast<MdListItem>();
      expect(items.map((i) => [i.text, i.depth, i.number]).toList(), [
        ['a', 0, null],
        ['b', 1, null],
        ['c', 0, 3],
        ['d', 0, 4],
      ]);
    });

    test('an indented continuation line joins its list item', () {
      final i = only<MdListItem>('- first line\n  continued');
      expect(i.text, 'first line\ncontinued');
    });

    test('a hyphen without a space is not a list; --- is a rule', () {
      expect(only<MdParagraph>('-nope').text, '-nope');
      expect(only<MdRule>('---'), isA<MdRule>());
      expect(only<MdRule>('* * *'), isA<MdRule>());
    });

    test('block quote merges consecutive lines', () {
      expect(only<MdQuote>('> a\n> b').text, 'a\nb');
    });

    test('GFM table with header, separator and rows; ragged rows survive', () {
      final t = only<MdTable>('| Name | Qty |\n|---|:-:|\n| a | 1 |\n| b |');
      expect(t.header, ['Name', 'Qty']);
      expect(t.rows, [
        ['a', '1'],
        ['b'],
      ]);
    });

    test('a pipe in prose without a separator row is just a paragraph', () {
      expect(only<MdParagraph>('a | b | c').text, 'a | b | c');
    });

    test('raw HTML is plain text, never interpreted', () {
      expect(only<MdParagraph>('<script>alert(1)</script>').text, '<script>alert(1)</script>');
    });

    test('empty and whitespace-only input', () {
      expect(parseMarkdown(''), isEmpty);
      expect(parseMarkdown('  \n\n  '), isEmpty);
    });

    test('CRLF is normalised', () {
      expect(parseMarkdown('a\r\n\r\nb').length, 2);
    });
  });

  group('inline', () {
    test('code span beats emphasis inside it', () {
      expect(inl('use `**x**` here'), [
        const MdInline('use '),
        const MdInline('**x**', code: true),
        const MdInline(' here'),
      ]);
    });

    test('bold, italic, both', () {
      expect(inl('**b**'), [const MdInline('b', bold: true)]);
      expect(inl('*i*'), [const MdInline('i', italic: true)]);
      expect(inl('__b__'), [const MdInline('b', bold: true)]);
      expect(inl('***x***'), [const MdInline('x', bold: true, italic: true)]);
    });

    test('nested emphasis and code inside bold', () {
      expect(inl('**a *b* `c`**'), [
        const MdInline('a ', bold: true),
        const MdInline('b', bold: true, italic: true),
        const MdInline(' ', bold: true),
        const MdInline('c', bold: true, code: true),
      ]);
    });

    test('snake_case and math-style asterisks stay literal', () {
      expect(inl('my_var_name'), [const MdInline('my_var_name')]);
      expect(inl('2 * 3 * 4'), [const MdInline('2 * 3 * 4')]);
      expect(inl('a_b_c and d'), [const MdInline('a_b_c and d')]);
    });

    test('unclosed markers stay literal (half-streamed text)', () {
      expect(inl('**bold so far'), [const MdInline('**bold so far')]);
      expect(inl('a `code so far'), [const MdInline('a `code so far')]);
      // Falls back to literal text; the bare URL inside may still autolink, but no
      // character is lost or reordered.
      expect(inl('[label](http://x').map((r) => r.text).join(), '[label](http://x');
    });

    test('backslash escapes', () {
      expect(inl(r'\*not italic\*'), [const MdInline('*not italic*')]);
    });

    test('links: only http(s); label keeps its style; bare URLs autolink', () {
      expect(inl('[docs](https://a.dev/x)'), [const MdInline('docs', url: 'https://a.dev/x')]);
      expect(inl('[bad](javascript:alert(1))'), [const MdInline('[bad](javascript:alert(1))')]);
      expect(inl('[f](file:///etc/passwd)'), [const MdInline('[f](file:///etc/passwd)')]);
      expect(inl('see https://a.dev.'), [const MdInline('see '), const MdInline('https://a.dev', url: 'https://a.dev'), const MdInline('.')]);
      expect(inl('[**b**](https://a.dev)'), [const MdInline('b', bold: true, url: 'https://a.dev')]);
    });

    test('a URL inside a code span is not linkified', () {
      expect(inl('`https://a.dev`'), [const MdInline('https://a.dev', code: true)]);
    });

    test('never throws on hostile or random input', () {
      for (final s in ['*', '**', '***', '****', '`', '``', '[', ']()', '[](', '\\', '_', '__', '*_*_', '`*`*`', '[[[[', '((((', '***a**', '**a***', '\u0000']) {
        expect(() => parseInline(s), returnsNormally, reason: s);
        expect(() => parseMarkdown(s), returnsNormally, reason: s);
      }
    });
  });

  group('MarkdownText', () {
    Future<void> pump(WidgetTester t, String md, {InlineSpan? trailing}) =>
        t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MarkdownText(md, trailing: trailing)))));

    testWidgets('renders code content, language label and a copy button', (t) async {
      await pump(t, 'Run:\n\n```bash\nflutter test\n```');
      expect(find.text('Run:'), findsOneWidget);
      expect(find.text('flutter test'), findsOneWidget);
      expect(find.text('bash'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);
    });

    testWidgets('an open (streaming) fence has no copy button yet', (t) async {
      await pump(t, '```bash\nflutter te');
      expect(find.text('flutter te'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsNothing);
    });

    testWidgets('link spans carry a tap recognizer; plain spans do not', (t) async {
      await pump(t, 'go to [docs](https://a.dev) now');
      final rich = t.widget<RichText>(find.byType(RichText).first);
      final spans = <TextSpan>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan) spans.add(s);
        return true;
      });
      final link = spans.firstWhere((s) => s.text == 'docs');
      expect(link.recognizer, isA<TapGestureRecognizer>());
      expect(link.style?.decoration, TextDecoration.underline);
      expect(spans.firstWhere((s) => s.text == 'go to ').recognizer, isNull);
    });

    testWidgets('lists, headings and tables render their text', (t) async {
      await pump(t, '# Big\n\n- one\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |');
      for (final s in ['Big', 'one', 'two', 'a', 'b', '1', '2']) {
        expect(find.text(s), findsWidgets, reason: s);
      }
      expect(find.text('•'), findsNWidgets(2));
    });

    testWidgets('the streaming cursor is kept after a code block', (t) async {
      await pump(t, '```\nx\n```', trailing: const WidgetSpan(child: SizedBox(key: Key('cursor'), width: 4, height: 4)));
      expect(find.byKey(const Key('cursor')), findsOneWidget);
    });

    testWidgets('empty text renders nothing and does not throw', (t) async {
      await pump(t, '');
      expect(find.byType(MarkdownText), findsOneWidget);
    });
  });
}
