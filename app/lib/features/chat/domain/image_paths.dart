/// Image file paths mentioned in an assistant reply (proposal 33) — e.g.
/// "Saved the plot to `out/chart.png`". The chat previews each through
/// `GET /sessions/:id/image`, which only serves real image bytes inside the
/// session's project; anything that doesn't resolve just doesn't render.
///
/// A path token: no whitespace/quotes/backticks/brackets, ending in a raster
/// image extension. URLs (`scheme://…`) are skipped — the daemon reads local
/// files only. Deduped, first-seen order, capped at [max].
List<String> extractImagePaths(String text, {int max = 6}) {
  final out = <String>[];
  for (final m in _pathRe.allMatches(text)) {
    final p = m.group(1)!;
    if (p.contains('://') || out.contains(p)) continue;
    out.add(p);
    if (out.length >= max) break;
  }
  return out;
}

final _pathRe = RegExp(
  r'''(?:^|[\s`'"(\[<])([^\s`'"()\[\]<>]+\.(?:png|jpe?g|gif|webp))(?=$|[\s`'")\]>.,:;!?])''',
  caseSensitive: false,
  multiLine: true,
);
