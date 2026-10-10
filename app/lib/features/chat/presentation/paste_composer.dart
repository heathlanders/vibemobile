import 'package:flutter/material.dart';

import '../../../core/spacing.dart';
import '../domain/paste_tokens.dart';
import 'diff_lines.dart';

/// Composer controller that draws each intact paste token as a chip (proposal
/// 47). The token stays plain text in the value, so caret and selection math
/// are unchanged; only its [TextSpan] is styled. (An editable can't host tap
/// recognizers, so taps are resolved by [tokenAt] from the field's onTap.)
class PasteTextController extends TextEditingController {
  PasteTextController(this.tokens);
  final PasteTokens tokens;

  static final _re = RegExp(r'\[Pasted text #\d+ \+\d+ lines\]');

  /// Range of the intact token the caret sits inside, or null.
  TextRange? tokenAt(int offset) {
    for (final m in _re.allMatches(text)) {
      if (offset > m.start && offset < m.end && tokens.textOf(m.group(0)!) != null) {
        return TextRange(start: m.start, end: m.end);
      }
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _re.allMatches(text)) {
      if (tokens.textOf(m.group(0)!) == null) continue; // edited by hand → plain text
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          backgroundColor: scheme.secondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ));
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}

/// What the user chose in [showPasteSheet].
enum PasteAction { expand, remove }

/// Full pasted text (scrollable, selectable) with Expand inline / Remove / Close.
Future<PasteAction?> showPasteSheet(BuildContext context, String text) {
  return showModalBottomSheet<PasteAction>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pasted text · ${PasteTokens.lineCount(text)} lines', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: Spacing.sm),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(text, style: monoStyle(ctx)),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(alignment: WrapAlignment.end, spacing: Spacing.sm, children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                TextButton(onPressed: () => Navigator.pop(ctx, PasteAction.remove), child: const Text('Remove')),
                FilledButton(onPressed: () => Navigator.pop(ctx, PasteAction.expand), child: const Text('Expand inline')),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A user bubble's text, folded to [PasteTokens.previewLines] lines when it
/// is over the paste limit. The full text is still what Copy puts on the clipboard.
class CollapsibleText extends StatefulWidget {
  const CollapsibleText(this.text, {super.key, required this.builder});
  final String text;
  final Widget Function(String text) builder;

  @override
  State<CollapsibleText> createState() => _CollapsibleTextState();
}

class _CollapsibleTextState extends State<CollapsibleText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (!PasteTokens.isLarge(text)) return widget.builder(text);
    final lines = text.split('\n');
    final hidden = lines.length - PasteTokens.previewLines;
    // A single huge line has no hidden lines; cut by characters instead.
    final foldable = hidden > 0;
    final shown = _open ? text : (foldable ? lines.take(PasteTokens.previewLines).join('\n') : text.substring(0, PasteTokens.maxChars));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.builder(shown),
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              _open ? 'Show less' : (foldable ? 'Show $hidden more lines' : 'Show more'),
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}
