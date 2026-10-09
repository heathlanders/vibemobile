/// Token/cost ledger aggregates from `GET /spend` (ADR 0017).
class SpendTotals {
  const SpendTotals({
    this.turns = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.cost = 0,
  });

  final int turns;
  final int input; // uncached input tokens
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final double cost;

  /// Every input token the model read: uncached + cache reads + cache writes.
  int get context => input + cacheRead + cacheWrite;

  /// Share of input served from the prompt cache (0–1); null with no input.
  double? get cacheHitRate => context == 0 ? null : cacheRead / context;

  factory SpendTotals.fromJson(Map<String, dynamic> j) {
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return SpendTotals(
      turns: i('turns'),
      input: i('input'),
      output: i('output'),
      cacheRead: i('cacheRead'),
      cacheWrite: i('cacheWrite'),
      cost: (j['cost'] as num?)?.toDouble() ?? 0,
    );
  }
}

class SpendRow {
  const SpendRow({required this.key, this.label, required this.totals, this.claudeMdBytes});
  final String key;
  final String? label; // project name when grouped by project
  final SpendTotals totals;

  /// Size of the project's root CLAUDE.md (project rows only; null = none).
  final int? claudeMdBytes;

  String get name => (label == null || label!.isEmpty) ? (key.isEmpty ? '(unknown)' : key) : label!;

  factory SpendRow.fromJson(Map<String, dynamic> j) =>
      SpendRow(
        key: (j['key'] as String?) ?? '',
        label: j['label'] as String?,
        totals: SpendTotals.fromJson(j),
        claudeMdBytes: (j['claudeMdBytes'] as num?)?.toInt(),
      );
}

class SpendReport {
  const SpendReport({required this.group, required this.days, required this.totals, required this.rows});
  final String group;
  final int days;
  final SpendTotals totals;
  final List<SpendRow> rows;

  factory SpendReport.fromJson(Map<String, dynamic> j) => SpendReport(
        group: j['group'] as String,
        days: (j['days'] as num).toInt(),
        totals: SpendTotals.fromJson((j['totals'] as Map).cast<String, dynamic>()),
        rows: ((j['rows'] as List?) ?? const [])
            .map((e) => SpendRow.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// A CLAUDE.md past this many bytes gets a tip — Claude Code's own "large
/// CLAUDE.md" warning fires at 40k characters (~10k tokens on every turn).
const claudeMdTipBytes = 40000;

/// Rule-based token-saving tips from a by-model report (plus, if given, a
/// by-project one for CLAUDE.md size). Pure → unit-tested. Each rule needs
/// enough turns to mean something; thresholds are deliberately conservative so
/// the list stays short.
List<String> savingsTips(SpendReport byModel, {SpendReport? byProject}) {
  final t = byModel.totals;
  final tips = <String>[];
  if (t.turns < 10) return tips;

  final hit = t.cacheHitRate;
  if (hit != null && hit < 0.5) {
    tips.add('Only ${(hit * 100).round()}% of input came from the prompt cache. Long-running sessions reuse '
        'their cache; starting many short ones re-sends the same context at full price.');
  }
  if (t.cacheWrite > t.cacheRead) {
    tips.add('The cache is written more than it is read — context keeps changing under it. Avoid editing '
        'CLAUDE.md or switching models mid-session.');
  }
  final avgContext = t.context / t.turns;
  if (avgContext > 150000) {
    tips.add('Turns average ${(avgContext / 1000).round()}k tokens of context. Run /compact, or start a '
        'fresh session for each new task.');
  }
  for (final r in byModel.rows) {
    final m = r.totals;
    if (m.turns < 10) continue;
    final perTurn = m.cost / m.turns;
    if (m.output / m.turns < 400 && perTurn > 0.05) {
      tips.add('${m.turns} short turns on ${r.name} averaged \$${perTurn.toStringAsFixed(2)} each — a faster, '
          'cheaper model fits quick edits and questions.');
    }
  }
  for (final r in byProject?.rows ?? const <SpendRow>[]) {
    final bytes = r.claudeMdBytes;
    if (bytes == null || bytes <= claudeMdTipBytes || r.totals.turns < 10) continue;
    tips.add('${r.name}\'s CLAUDE.md is ${(bytes / 1000).round()} KB (~${(bytes / 4000).round()}k tokens), '
        'loaded into every turn. Move rarely needed detail into docs it points to.');
  }
  return tips;
}
