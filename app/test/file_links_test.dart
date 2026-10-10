import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/file_refs.dart';
import 'package:vibemobile/features/chat/domain/markdown.dart';
import 'package:vibemobile/features/chat/presentation/linkified_text.dart';
import 'package:vibemobile/features/chat/presentation/markdown_text.dart';

void main() {
  group('detectFileRef (inline code)', () {
    test('positives', () {
      expect(detectFileRef('src/x.ts:42'), const FileRef('src/x.ts', 42));
      expect(detectFileRef('app/lib/a.dart:10:5'), const FileRef('app/lib/a.dart', 10));
      expect(detectFileRef('README.md'), const FileRef('README.md'));
      expect(detectFileRef('docs/foo'), const FileRef('docs/foo'));
      expect(detectFileRef('./docs/a.md'), const FileRef('docs/a.md'));
      expect(detectFileRef('/etc/hosts'), const FileRef('/etc/hosts'));
      expect(detectFileRef('.env.example'), const FileRef('.env.example'));
      expect(detectFileRef('Dockerfile'), const FileRef('Dockerfile'));
    });
    test('negatives', () {
      for (final t in [
        '1.0.17', 'v2.3', 'e.g.', 'i.e.', 'example.com', 'foo.org', 'x.dev', 'word', '..', '../a.md', 'a/../b.md', '.',
        'https://x.dev/a.md', 'javascript:alert(1)', 'file:///etc/passwd', 'www.x.com/a.md', 'two words.md', '1/2', '', '//a.md',
      ]) {
        expect(detectFileRef(t), isNull, reason: t);
      }
    });
  });

  group('fileRefFromLinkTarget', () {
    test('relative targets', () {
      expect(fileRefFromLinkTarget('./PLAN.md#x'), const FileRef('PLAN.md'));
      expect(fileRefFromLinkTarget('docs/a.md:7'), const FileRef('docs/a.md', 7));
      expect(fileRefFromLinkTarget('src/lib'), const FileRef('src/lib'));
    });
    test('schemes and URLs are never file refs', () {
      for (final t in ['javascript:alert(1)', 'file:///etc/passwd', 'mailto:a@b.c', 'http://x.dev/a.md', '//x.dev/a.md', 'www.x.com', '#top', '']) {
        expect(fileRefFromLinkTarget(t), isNull, reason: t);
      }
    });
  });

  group('splitFileRefs (bare text, stricter)', () {
    List<FileRef> refs(String t) => [for (final s in splitFileRefsSkippingUrls(t)) ?s.ref];

    test('positives, trailing punctuation stripped', () {
      expect(refs('see docs/proposals/46-file-browser.md.'), [const FileRef('docs/proposals/46-file-browser.md')]);
      expect(refs('open (src/x.ts:42), then README.md'), [const FileRef('src/x.ts', 42), const FileRef('README.md')]);
      expect(refs('edit package.json; pubspec.yaml: done'), [const FileRef('package.json'), const FileRef('pubspec.yaml')]);
      final segs = splitFileRefs('see docs/a.md.');
      expect(segs.map((s) => s.text).join(), 'see docs/a.md.');
      expect(segs[1].text, 'docs/a.md');
    });
    test('negatives', () {
      for (final t in [
        'version 1.0.17 and v2.3', 'e.g. this, i.e. that', 'visit example.com', 'a/b', 'foo.dart', 'and/or', 'Node.js',
        'file:///etc/passwd', 'javascript:alert(1)', 'www.x.com/a.md', 'https://x.dev/a.md and ftp://h/a.md',
      ]) {
        expect(refs(t), isEmpty, reason: t);
      }
    });
  });

  group('parseInline', () {
    test('off by default: nothing changes', () {
      expect(parseInline('`a/b.md` and [p](./PLAN.md)').every((r) => r.file == null), true);
    });
    test('code, bare text, and markdown links', () {
      final r = parseInline('see `src/x.ts:42` and docs/a.md or [plan](./PLAN.md#x)', fileRefs: true);
      expect([for (final x in r) if (x.file != null) x.file], [const FileRef('src/x.ts', 42), const FileRef('docs/a.md'), const FileRef('PLAN.md')]);
      expect(r.firstWhere((x) => x.file?.path == 'src/x.ts').code, true);
    });
    test('urls stay urls; bad link targets stay literal', () {
      final r = parseInline('[x](https://x.dev/a.md) [y](javascript:alert(1)) [z](file:///etc/passwd)', fileRefs: true);
      expect(r.where((x) => x.file != null), isEmpty);
      expect(r.where((x) => x.url != null).map((x) => x.url), ['https://x.dev/a.md']);
    });
  });

  group('widgets', () {
    Future<void> tapSpan(WidgetTester t, String text) async {
      final rich = t.widgetList<RichText>(find.byType(RichText)).firstWhere((w) => w.text.toPlainText().contains(text));
      TapGestureRecognizer? rec;
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text == text && s.recognizer is TapGestureRecognizer) rec = s.recognizer as TapGestureRecognizer;
        return true;
      });
      expect(rec, isNotNull, reason: '$text should be a link');
      rec!.onTap!();
    }

    testWidgets('tapping a file link calls onOpenFile with path and line', (t) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkdownText('look at `src/x.ts:42` and [plan](./PLAN.md)', onOpenFile: (p, l) => opened.add('$p:$l')),
        ),
      ));
      await tapSpan(t, 'src/x.ts:42');
      await tapSpan(t, 'plan');
      expect(opened, ['src/x.ts:42', 'PLAN.md:null']);
    });

    testWidgets('LinkifiedText links bare paths too', (t) async {
      final opened = <String>[];
      await t.pumpWidget(MaterialApp(home: Scaffold(body: LinkifiedText('see docs/a.md:3 now', onOpenFile: (p, l) => opened.add('$p:$l')))));
      await tapSpan(t, 'docs/a.md:3');
      expect(opened, ['docs/a.md:3']);
    });

    testWidgets('without onOpenFile nothing is linkified', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: Column(children: [MarkdownText('`src/x.ts:42` docs/a.md [p](./PLAN.md)'), LinkifiedText('docs/a.md')])),
      ));
      var recognizers = 0;
      for (final w in t.widgetList<RichText>(find.byType(RichText))) {
        w.text.visitChildren((s) {
          if (s is TextSpan && s.recognizer != null) recognizers++;
          return true;
        });
      }
      expect(recognizers, 0);
    });
  });
}
