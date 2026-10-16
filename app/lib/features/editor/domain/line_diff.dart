/// A unified-style line diff of [a] (server) against [b] (buffer): lines prefixed `+`, `-` or a
/// space, with [context] unchanged lines around each change and `…` where the rest was skipped.
/// Common head and tail are trimmed first; a middle too big to diff exactly (more than ~4M cells)
/// is shown as wholly removed then wholly added. Empty when the texts are equal.
List<String> lineDiff(String a, String b, {int context = 3}) {
  if (a == b) return const [];
  final x = a.split('\n'), y = b.split('\n');
  var head = 0;
  while (head < x.length && head < y.length && x[head] == y[head]) {
    head++;
  }
  var tail = 0;
  while (tail < x.length - head && tail < y.length - head && x[x.length - 1 - tail] == y[y.length - 1 - tail]) {
    tail++;
  }
  final mx = x.sublist(head, x.length - tail), my = y.sublist(head, y.length - tail);
  final ops = <String>[]; // the middle only
  if (mx.length * my.length > 4000000) {
    ops
      ..addAll(mx.map((l) => '-$l'))
      ..addAll(my.map((l) => '+$l'));
  } else {
    final n = mx.length, m = my.length;
    final t = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i][j] = mx[i] == my[j] ? t[i + 1][j + 1] + 1 : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (mx[i] == my[j]) {
        ops.add(' ${mx[i]}');
        i++;
        j++;
      } else if (t[i + 1][j] >= t[i][j + 1]) {
        ops.add('-${mx[i++]}');
      } else {
        ops.add('+${my[j++]}');
      }
    }
    while (i < n) {
      ops.add('-${mx[i++]}');
    }
    while (j < m) {
      ops.add('+${my[j++]}');
    }
  }
  final all = [
    for (var i = 0; i < head; i++) ' ${x[i]}',
    ...ops,
    for (var i = x.length - tail; i < x.length; i++) ' ${x[i]}',
  ];
  // Keep changed lines and `context` lines around them.
  final keep = List.filled(all.length, false);
  for (var i = 0; i < all.length; i++) {
    if (all[i].startsWith(' ')) continue;
    for (var k = i - context; k <= i + context; k++) {
      if (k >= 0 && k < all.length) keep[k] = true;
    }
  }
  final out = <String>[];
  var skipped = false;
  for (var i = 0; i < all.length; i++) {
    if (keep[i]) {
      out.add(all[i]);
      skipped = false;
    } else if (!skipped) {
      out.add('…');
      skipped = true;
    }
  }
  return out;
}
