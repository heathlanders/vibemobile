import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/link_spans.dart';

/// Chat text with http(s) URLs as tappable links (proposal 34). Links open in
/// the external browser, never in-app. [trailing] is appended after the text
/// (the streaming cursor).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(this.text, {super.key, this.trailing});
  final String text;
  final InlineSpan? trailing;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

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

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final linkStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final spans = <InlineSpan>[];
    for (final s in splitLinks(widget.text)) {
      if (!s.isLink) {
        spans.add(TextSpan(text: s.text));
        continue;
      }
      final uri = Uri.tryParse(s.text);
      final r = TapGestureRecognizer()
        ..onTap = uri == null ? null : () => launchUrl(uri, mode: LaunchMode.externalApplication);
      _recognizers.add(r);
      spans.add(TextSpan(text: s.text, style: linkStyle, recognizer: r));
    }
    if (widget.trailing != null) spans.add(widget.trailing!);
    return Text.rich(TextSpan(children: spans));
  }
}
