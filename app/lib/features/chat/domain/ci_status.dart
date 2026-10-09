/// Pull request + CI status of a chat's branch (`GET /sessions/:id/ci`, proposal 45).
/// Read-only: the daemon only lists; nothing here can change GitHub.
class CiCheck {
  const CiCheck(this.name, this.state, [this.url]);
  final String name;

  /// `passing` | `failing` | `pending` | `skipped`.
  final String state;
  final String? url;
}

class CiPullRequest {
  const CiPullRequest({required this.number, required this.title, required this.state, required this.url, this.isDraft = false, this.review, this.mergeState});
  final int number;
  final String title, state, url;
  final bool isDraft;
  final String? review, mergeState;

  /// "Open" / "Merged" / "Closed" / "Draft".
  String get stateLabel => isDraft && state == 'OPEN' ? 'Draft' : '${state.isEmpty ? '?' : state[0]}${state.length > 1 ? state.substring(1).toLowerCase() : ''}';

  /// "Approved" / "Changes requested" / "Review required" / null.
  String? get reviewLabel => switch (review) {
        'APPROVED' => 'Approved',
        'CHANGES_REQUESTED' => 'Changes requested',
        'REVIEW_REQUIRED' => 'Review required',
        _ => null,
      };

  /// Only the merge states worth saying out loud.
  String? get mergeLabel => switch (mergeState) {
        'CLEAN' => 'Ready to merge',
        'BLOCKED' => 'Blocked',
        'BEHIND' => 'Behind the base branch',
        'DIRTY' => 'Has conflicts',
        'UNSTABLE' => 'Some checks are failing',
        _ => null,
      };
}

class CiStatus {
  const CiStatus({required this.available, this.reason, this.repo, this.branch, this.pr, this.checks = const [], this.checksState = 'none', this.runs = const []});
  final bool available;

  /// Why nothing is shown (not GitHub, not signed in, …) — a fixed, short sentence from the daemon.
  final String? reason;
  final String? repo, branch;
  final CiPullRequest? pr;
  final List<CiCheck> checks;

  /// `passing` | `failing` | `pending` | `none`.
  final String checksState;
  final List<CiCheck> runs;

  /// Type-safe: junk degrades to "unavailable", never throws.
  factory CiStatus.fromJson(Object? j) {
    if (j is! Map) return const CiStatus(available: false, reason: 'unexpected reply');
    if (j['available'] != true) return CiStatus(available: false, reason: j['reason'] is String ? j['reason'] as String : 'not available');
    String? s(Object? x) => x is String ? x : null;
    CiCheck? check(Object? c) => c is Map && c['name'] is String ? CiCheck(c['name'] as String, s(c['state']) ?? 'pending', s(c['url'])) : null;
    final p = j['pr'];
    return CiStatus(
      available: true,
      repo: s(j['repo']),
      branch: s(j['branch']),
      pr: p is Map && p['number'] is num
          ? CiPullRequest(
              number: (p['number'] as num).toInt(),
              title: s(p['title']) ?? '',
              state: s(p['state']) ?? '',
              url: s(p['url']) ?? '',
              isDraft: p['isDraft'] == true,
              review: s(p['review']),
              mergeState: s(p['mergeState']),
            )
          : null,
      checks: [if (j['checks'] is List) for (final c in j['checks'] as List) ?check(c)],
      checksState: s(j['checksState']) ?? 'none',
      runs: [if (j['runs'] is List) for (final r in j['runs'] as List) ?check(r)],
    );
  }
}
