import 'rollover.dart';
/// Context-window reading from the daemon's `context` frame (proposal 40). The window
/// is what limits a long conversation: past it the model forgets or the SDK compacts.
class ContextCategory {
  const ContextCategory(this.name, this.tokens);
  final String name;
  final int tokens;
}

/// An instruction file the session loaded (CLAUDE.md, auto-memory, …).
class MemoryFileInfo {
  const MemoryFileInfo(this.path, this.type, this.tokens);
  final String path;
  final String type;
  final int tokens;

  /// "CLAUDE.md" / "MEMORY.md" — the last path segment.
  String get fileName => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

  /// What the SDK calls the source, in words a person would use.
  String get kind => switch (type) {
        'Project' => 'Project instructions',
        'AutoMem' => 'Auto memory',
        'User' => 'Your global instructions',
        'Local' => 'Local project notes',
        '' => 'Instructions',
        _ => type,
      };
}

class ContextUsage {
  const ContextUsage({
    required this.tokens,
    required this.max,
    required this.percent,
    this.autoCompactAt,
    this.categories = const [],
    this.memoryFiles = const [],
    this.rulesApplied,
    this.model,
  });

  final int tokens;
  final int max;

  /// 0..100+ (can exceed 100 when over the window).
  final int percent;

  /// Tokens at which the SDK compacts by itself; null when auto-compaction is off.
  final int? autoCompactAt;

  /// Only what occupies the window, largest first.
  final List<ContextCategory> categories;
  final String? model;

  /// Instruction files loaded into this session; empty from older daemons.
  final List<MemoryFileInfo> memoryFiles;

  /// Whether the daemon's session rules (ADR 0026) were appended when THIS session started;
  /// null from daemons that don't say.
  final bool? rulesApplied;

  // Every read is type-checked: a malformed frame must degrade to zeros, never throw out
  // of the frame handler (that would stall the whole chat).
  factory ContextUsage.fromFrame(Map<String, dynamic> f) {
    int n(Object? x) => x is num ? x.toInt() : 0;
    final auto = f['autoCompactAt'];
    final cats = f['categories'];
    return ContextUsage(
      tokens: n(f['tokens']),
      max: n(f['max']),
      percent: n(f['percent']),
      autoCompactAt: auto is num ? auto.toInt() : null,
      categories: [
        if (cats is List)
          for (final c in cats)
            if (c is Map) ContextCategory('${c['name']}', n(c['tokens'])),
      ],
      model: f['model'] is String ? f['model'] as String : null,
      memoryFiles: [
        if (f['memoryFiles'] is List)
          for (final m in f['memoryFiles'] as List)
            if (m is Map && m['path'] is String)
              MemoryFileInfo(m['path'] as String, m['type'] is String ? m['type'] as String : '', n(m['tokens'])),
      ],
      rulesApplied: f['rules'] is bool ? f['rules'] as bool : null,
    );
  }

  /// 0..1 for a progress bar.
  double get fraction => max <= 0 ? 0 : (tokens / max).clamp(0.0, 1.0);

  /// Share of the window used relative to where auto-compaction kicks in, when known —
  /// what actually predicts "the conversation is about to be summarized".
  double? get fractionOfCompactPoint =>
      autoCompactAt == null || autoCompactAt! <= 0 ? null : (tokens / autoCompactAt!).clamp(0.0, 1.0);

  /// Worth the user's attention: 80% of the way to auto-compaction (or of the window).
  bool get high => (fractionOfCompactPoint ?? fraction) >= 0.8;

  /// Time to offer "write a handoff & start fresh" (ADR 0028) — before auto-compaction, not at it.
  bool get nudgeFresh => (fractionOfCompactPoint ?? fraction) >= freshNudgeAt;

  /// "26k / 1M · 3%" — compact enough for a one-line strip.
  String get label => '${tokenLabel(tokens)} / ${tokenLabel(max)} · $percent%';
}

/// 950 → "950", 26321 → "26k", 1500000 → "1.5M".
String tokenLabel(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return '${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}
