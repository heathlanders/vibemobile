import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/git_sheet.dart';
import 'package:vibemobile/features/projects/data/git_api.dart';

GitFile f(String path, {String index = ' ', String worktree = 'M'}) => GitFile(path: path, index: index, worktree: worktree);

class FakeGitApi extends GitApi {
  FakeGitApi(this.files, {this.stageResult, this.commitResult, this.branchResult}) : super(Dio());
  final List<GitFile> files;
  GitWriteResult? stageResult, commitResult, branchResult;
  final calls = <String>[];
  List<String>? stagedPaths;
  String? message;

  @override
  Future<GitStatus> sessionStatus(String sessionId) async =>
      GitStatus(repo: true, clean: files.isEmpty, files: files, truncated: false, branch: 'vibe/s_1');

  @override
  Future<GitWriteResult> stage(String sessionId, List<String> paths) async {
    calls.add('stage');
    stagedPaths = paths;
    return stageResult ?? GitWriteResult(ok: true, staged: paths);
  }

  @override
  Future<GitWriteResult> commit(String sessionId, String message) async {
    calls.add('commit');
    this.message = message;
    return commitResult ?? const GitWriteResult(ok: true, sha: 'abcdef1234567890', subject: 'subj');
  }

  @override
  Future<GitWriteResult> branch(String sessionId, String name) async {
    calls.add('branch $name');
    return branchResult ?? const GitWriteResult(ok: true);
  }
}

void main() {
  group('GitFile', () {
    test('staged = in the index; untracked and clean-index are not', () {
      expect(f('a', index: 'M', worktree: ' ').staged, true);
      expect(f('a', index: 'A', worktree: ' ').staged, true);
      expect(f('a', index: ' ').staged, false);
      expect(f('a', index: '?', worktree: '?').staged, false);
    });

    test('looksSecret mirrors the daemon deny-list, by basename', () {
      for (final p in ['.env', '.env.local', 'cfg/.env.prod', 'k.pem', 'a/b/server.key', 'id_rsa', 'x/id_ed25519.pub', '.netrc', 'c.p12']) {
        expect(f(p).looksSecret, true, reason: p);
      }
      for (final p in ['environment.ts', 'README.md', 'src/keyboard.dart', 'monkey.txt']) {
        expect(f(p).looksSecret, false, reason: p);
      }
    });
  });

  test('defaultSelection ticks only the session\'s own, unstaged, non-secret edits', () {
    final files = [f('mine.dart'), f('other.dart'), f('.env'), f('staged.dart', index: 'M', worktree: ' ')];
    final sel = defaultSelection(files, {'mine.dart', '.env', 'staged.dart', 'gone.dart'});
    expect(sel, {'mine.dart'});
  });

  test('GitWriteResult: ok only on 200; error text from the body; short sha', () {
    expect(GitWriteResult.fromResponse(200, {'sha': 'abcdef1234567890'}).shortSha, 'abcdef1');
    final bad = GitWriteResult.fromResponse(409, {'error': 'nothing staged'});
    expect(bad.ok, false);
    expect(bad.error, 'nothing staged');
    expect(GitWriteResult.fromResponse(500, null).error, contains('500'));
  });

  group('GitSheet', () {
    Future<FakeGitApi> pump(WidgetTester tester, List<GitFile> files, {Set<String> edited = const {}, FakeGitApi? api}) async {
      final a = api ?? FakeGitApi(files);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GitSheet(api: a, sessionId: 's1', loadEdited: () async => edited)),
      ));
      await tester.pumpAndSettle();
      return a;
    }

    FilledButton commitButton(WidgetTester t) => t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Commit'));

    testWidgets('pre-ticks the session\'s edits; commit needs a message', (tester) async {
      await pump(tester, [f('mine.dart'), f('other.dart')], edited: {'mine.dart'});
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'mine.dart')).value, true);
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'other.dart')).value, false);
      expect(commitButton(tester).onPressed, isNull, reason: 'no message yet');
      await tester.enterText(find.byType(TextField), 'fix: thing');
      await tester.pump();
      expect(commitButton(tester).onPressed, isNotNull);
    });

    testWidgets('stages exactly the ticked files, then commits the trimmed message', (tester) async {
      final api = await pump(tester, [f('mine.dart'), f('other.dart')], edited: {'mine.dart'});
      await tester.tap(find.widgetWithText(CheckboxListTile, 'other.dart'));
      await tester.enterText(find.byType(TextField), '  fix: thing  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
      await tester.pumpAndSettle();
      expect(api.calls, ['stage', 'commit']);
      expect(api.stagedPaths!.toSet(), {'mine.dart', 'other.dart'});
      expect(api.message, 'fix: thing');
    });

    testWidgets('a secret-looking file is shown but cannot be ticked, so is never sent', (tester) async {
      final api = await pump(tester, [f('.env'), f('a.dart')], edited: {'.env', 'a.dart'});
      final tile = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, '.env'));
      expect(tile.onChanged, isNull);
      expect(tile.value, false);
      expect(find.text('looks like a secret — not offered'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'm');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
      await tester.pumpAndSettle();
      expect(api.stagedPaths, ['a.dart']);
    });

    testWidgets('already-staged files count toward the commit and are not re-staged', (tester) async {
      final api = await pump(tester, [f('s.dart', index: 'M', worktree: ' ')]);
      expect(find.text('already staged'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'm');
      await tester.pump();
      expect(commitButton(tester).onPressed, isNotNull, reason: 'staged files alone are committable');
      await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
      await tester.pumpAndSettle();
      expect(api.calls, ['commit'], reason: 'nothing ticked ⇒ no stage call');
    });

    testWidgets('a refused stage shows the daemon\'s message and never commits', (tester) async {
      final api = FakeGitApi([f('a.dart')], stageResult: const GitWriteResult(ok: false, error: 'a.dart: outside the project'));
      await pump(tester, [], api: api, edited: {'a.dart'});
      await tester.enterText(find.byType(TextField), 'm');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Commit'));
      await tester.pumpAndSettle();
      expect(find.text('a.dart: outside the project'), findsOneWidget);
      expect(api.calls, ['stage']);
    });

    testWidgets('a clean tree says so and offers no commit', (tester) async {
      await pump(tester, const []);
      expect(find.text('Nothing to commit — the working tree is clean.'), findsOneWidget);
      expect(commitButton(tester).onPressed, isNull);
    });

    testWidgets('new branch calls the API with the typed name', (tester) async {
      final api = await pump(tester, [f('a.dart')]);
      await tester.tap(find.text('vibe/s_1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'feat/x');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(api.calls, ['branch feat/x']);
    });
  });
}
