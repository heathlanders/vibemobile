import 'package:flutter/services.dart';

/// Large-paste collapsing (proposal 47). A single insertion over [maxLines]
/// lines or [maxChars] characters is swapped for a `[Pasted text #N +L lines]`
/// token in the composer; the real text waits in [pastes] and is put back by
/// [expand] right before the message is sent.
class PasteTokens {
  static const maxLines = 10;
  static const maxChars = 1000;

  /// Lines shown by a collapsed transcript bubble.
  static const previewLines = 6;

  static final _token = RegExp(r'\[Pasted text #(\d+) \+(\d+) lines\]');

  /// `#N -> text` for the tokens currently in the composer.
  final Map<int, String> pastes = {};
  int _next = 1;

  static int lineCount(String s) => '\n'.allMatches(s).length + 1;

  /// Over the limit: more than [maxLines] lines or more than [maxChars] characters.
  static bool isLarge(String s) => s.length > maxChars || lineCount(s) > maxLines;

  static String tokenFor(int n, String text) => '[Pasted text #$n +${lineCount(text)} lines]';

  /// Stores [text] and returns the token standing in for it.
  String add(String text) {
    final n = _next++;
    pastes[n] = text;
    return tokenFor(n, text);
  }

  /// The pasted text a token string stands for; null if it is not an intact token.
  String? textOf(String token) {
    final m = _token.firstMatch(token);
    if (m == null || m.start != 0 || m.end != token.length) return null;
    final n = int.parse(m.group(1)!);
    final text = pastes[n];
    return text != null && tokenFor(n, text) == token ? text : null;
  }

  /// Replaces every intact token in [s] with its text. A token the user edited
  /// no longer matches and stays as literal text.
  String expand(String s) => s.replaceAllMapped(_token, (m) => textOf(m.group(0)!) ?? m.group(0)!);

  /// Drops the stored text behind [token] (no-op if it is not an intact token).
  void forget(String token) {
    if (textOf(token) != null) pastes.remove(int.parse(_token.firstMatch(token)!.group(1)!));
  }

  /// Forget every paste (after a send); numbering restarts at #1.
  void clear() {
    pastes.clear();
    _next = 1;
  }

  /// If [next] differs from [old] by one contiguous large insertion, returns
  /// [next] with that run swapped for a token and the caret after it.
  TextEditingValue collapse(TextEditingValue old, TextEditingValue next) {
    final o = old.text, n = next.text;
    var p = 0;
    final maxP = o.length < n.length ? o.length : n.length;
    while (p < maxP && o.codeUnitAt(p) == n.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    final maxS = (o.length < n.length ? o.length : n.length) - p;
    while (s < maxS && o.codeUnitAt(o.length - 1 - s) == n.codeUnitAt(n.length - 1 - s)) {
      s++;
    }
    final run = n.substring(p, n.length - s);
    if (!isLarge(run)) return next;
    final token = add(run);
    return TextEditingValue(
      text: n.replaceRange(p, n.length - s, token),
      selection: TextSelection.collapsed(offset: p + token.length),
    );
  }

  /// Inserts [text] over [value]'s selection (end of text if none), collapsing
  /// it when large. Used by the desktop Ctrl/Cmd+V path, which bypasses formatters.
  TextEditingValue insert(TextEditingValue value, String text) {
    final sel = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    final next = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    return collapse(value, next);
  }
}

/// Runs [PasteTokens.collapse] on every edit the framework applies to the field.
class PasteCollapseFormatter extends TextInputFormatter {
  PasteCollapseFormatter(this.tokens);
  final PasteTokens tokens;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      tokens.collapse(oldValue, newValue);
}
