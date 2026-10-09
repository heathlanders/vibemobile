import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/spacing.dart';
import '../../../core/theme.dart';
import '../domain/markdown.dart';

/// Assistant text rendered as markdown (see domain/markdown.dart for the subset).
/// Links open in the external browser, never in-app (same rule as [LinkifiedText]).
/// [trailing] (the streaming cursor) is appended to the last text block.
class MarkdownText extends StatefulWidget {
  const MarkdownText(this.text, {super.key, this.trailing});
  final String text;
  final InlineSpan? trailing;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  final _recognizers = <TapGestureRecognizer>[];
  String? _parsedFor;
  List<MdBlock> _blocks = const [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  List<InlineSpan> _spans(String text, ThemeData theme, {TextStyle? base}) {
    final out = <InlineSpan>[];
    for (final r in parseInline(text)) {
      var style = base ?? const TextStyle();
      if (r.bold) style = style.copyWith(fontWeight: FontWeight.w700);
      if (r.italic) style = style.copyWith(fontStyle: FontStyle.italic);
      if (r.code) {
        style = style.copyWith(
          fontFamily: AppTheme.monoFontFamily,
          fontSize: (style.fontSize ?? 14) * 0.9,
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
        );
      }
      GestureRecognizer? rec;
      if (r.url != null) {
        style = style.copyWith(color: theme.colorScheme.primary, decoration: TextDecoration.underline);
        final uri = Uri.tryParse(r.url!);
        final t = TapGestureRecognizer()
          ..onTap = uri == null ? null : () => launchUrl(uri, mode: LaunchMode.externalApplication);
        _recognizers.add(t);
        rec = t;
      }
      out.add(TextSpan(text: r.text, style: style, recognizer: rec));
    }
    return out;
  }

  Widget _rich(String text, ThemeData theme, InlineSpan? trailing, {TextStyle? base}) {
    final spans = _spans(text, theme, base: base);
    if (trailing != null) spans.add(trailing);
    return Text.rich(TextSpan(children: spans, style: base));
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    if (_parsedFor != widget.text) {
      _blocks = parseMarkdown(widget.text);
      _parsedFor = widget.text;
    }
    final theme = Theme.of(context);
    final blocks = _blocks;
    if (blocks.isEmpty) {
      return widget.trailing == null ? const SizedBox.shrink() : Text.rich(TextSpan(children: [widget.trailing!]));
    }
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final last = i == blocks.length - 1;
      final cursor = last ? widget.trailing : null;
      final w = _block(blocks[i], theme, cursor);
      // Code/table/rule can't hold the cursor inline; put it under them.
      final needsOwnLine = last && cursor != null && (blocks[i] is MdCode || blocks[i] is MdTable || blocks[i] is MdRule);
      children.add(Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : Spacing.sm), child: w));
      if (needsOwnLine) children.add(Text.rich(TextSpan(children: [cursor])));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }

  Widget _block(MdBlock b, ThemeData theme, InlineSpan? cursor) {
    final body = theme.textTheme.bodyMedium;
    switch (b) {
      case MdParagraph():
        return _rich(b.text, theme, cursor);
      case MdHeading():
        final scale = switch (b.level) { 1 => 1.4, 2 => 1.25, 3 => 1.12, _ => 1.0 };
        return _rich(b.text, theme, cursor,
            base: TextStyle(fontWeight: FontWeight.w700, fontSize: (body?.fontSize ?? 14) * scale));
      case MdCode():
        return _CodeBlock(code: b.code, lang: b.lang, closed: b.closed);
      case MdListItem():
        final marker = b.number != null ? '${b.number}.' : (b.depth == 0 ? '•' : '◦');
        return Padding(
          padding: EdgeInsets.only(left: b.depth * 16.0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 24, child: Text(marker)),
            Expanded(child: _rich(b.text, theme, cursor)),
          ]),
        );
      case MdQuote():
        return Container(
          padding: const EdgeInsets.only(left: Spacing.sm),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3))),
          child: _rich(b.text, theme, cursor, base: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        );
      case MdRule():
        return const Divider(height: 1);
      case MdTable():
        return _table(b, theme);
    }
  }

  Widget _table(MdTable t, ThemeData theme) {
    final cols = t.header.length;
    TableRow row(List<String> cells, {bool head = false}) => TableRow(
          decoration: head ? BoxDecoration(color: theme.colorScheme.surfaceContainerHigh) : null,
          children: [
            for (var c = 0; c < cols; c++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 4),
                child: _rich(c < cells.length ? cells[c] : '', theme, null,
                    base: head ? const TextStyle(fontWeight: FontWeight.w700) : null),
              ),
          ],
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: theme.colorScheme.outlineVariant),
        children: [row(t.header, head: true), for (final r in t.rows) row(r)],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.lang, required this.closed});
  final String code;
  final String lang;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: Spacing.sm),
          child: Row(children: [
            Expanded(child: Text(lang, style: theme.textTheme.labelSmall)),
            if (closed)
              IconButton(
                tooltip: 'Copy code',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
                },
              )
            else
              const SizedBox(height: 28),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Spacing.sm, 0, Spacing.sm, Spacing.sm),
          child: Text(code, style: const TextStyle(fontFamily: AppTheme.monoFontFamily, fontSize: 12.5, height: 1.35)),
        ),
      ]),
    );
  }
}
