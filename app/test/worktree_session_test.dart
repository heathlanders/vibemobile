import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/sessions/data/session_api.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

void main() {
  test('Session parses worktree_branch; absent means not isolated', () {
    final base = {'id': 's_1', 'project_id': 'p', 'kind': 'claude', 'status': 'live', 'created_at': 't'};
    expect(Session.fromJson({...base, 'worktree_branch': 'vibe/s_1'}).worktreeBranch, 'vibe/s_1');
    expect(Session.fromJson(base).worktreeBranch, isNull);
    expect(Session.fromJson({...base, 'worktree_branch': null}).worktreeBranch, isNull);
  });

  test('WorktreeKept wording names the reason and where the copy is', () {
    final dirty = WorktreeKept.fromJson({'kept': true, 'path': '/p/.vibe-worktrees/s_1', 'branch': 'vibe/s_1', 'reason': 'dirty'});
    expect(dirty.message, contains('uncommitted changes'));
    expect(dirty.message, contains('/p/.vibe-worktrees/s_1'));
    expect(dirty.message, contains('vibe/s_1'));
    expect(WorktreeKept.fromJson({'path': '/x', 'reason': 'commits'}).message, contains('unmerged commits'));
    expect(WorktreeKept.fromJson({'path': '/x'}).message, contains('could not be checked'));
  });
}
