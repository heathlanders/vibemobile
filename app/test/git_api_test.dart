import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/projects/data/git_api.dart';

void main() {
  GitStatus parse(Map<String, dynamic> j) => GitStatus.fromJson(j);

  test('dirty repo summarises branch, count and ahead/behind', () {
    final s = parse({
      'repo': true,
      'branch': 'main',
      'ahead': 1,
      'behind': 2,
      'clean': false,
      'truncated': false,
      'files': [
        {'path': 'lib/a.dart', 'index': ' ', 'worktree': 'M'},
        {'path': 'new.txt', 'index': '?', 'worktree': '?'},
      ],
    });
    expect(s.summary, 'main · 2 changed · ahead 1 · behind 2');
    expect(s.files.last.untracked, true);
    expect(s.files.first.untracked, false);
  });

  test('clean repo says so', () {
    final s = parse({'repo': true, 'branch': 'main', 'clean': true, 'files': [], 'truncated': false});
    expect(s.summary, 'main · clean');
  });

  test('a server-capped list is marked in the summary', () {
    final s = parse({
      'repo': true,
      'branch': 'main',
      'clean': false,
      'truncated': true,
      'files': [
        {'path': 'a', 'index': 'M', 'worktree': ' '},
      ],
    });
    expect(s.summary, contains('1+ changed'));
  });

  test('non-repo project is reported, not faked', () {
    final s = parse({'repo': false, 'clean': true, 'files': [], 'truncated': false});
    expect(s.repo, false);
    expect(s.summary, 'Not a git repo');
  });
}
