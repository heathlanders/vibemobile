import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';
import 'package:vibemobile/features/tasks/data/task_api.dart';
import 'package:vibemobile/features/tasks/domain/task.dart';
import 'package:vibemobile/features/tasks/presentation/tasks_panel.dart';

class _FakeApi extends TaskApi {
  _FakeApi(this.tasks) : super(Dio());
  List<Task> tasks;
  final dispatched = <String>[];

  @override
  Future<List<Task>> list(String projectId) async => tasks;

  @override
  Future<String> dispatch(String id) async {
    dispatched.add(id);
    return 's_1';
  }
}

void main() {
  test('Task.fromJson reads scope, deps and the session', () {
    final t = Task.fromJson({
      'id': 't1',
      'project_id': 'p1',
      'title': 'Do it',
      'body': 'goal',
      'scope': ['src/a', 'docs'],
      'deps': ['t0'],
      'state': 'running',
      'session_id': 's_9',
    });
    expect(t.scope, ['src/a', 'docs']);
    expect(t.deps, ['t0']);
    expect(t.state, 'running');
    expect(t.sessionId, 's_9');
    final bare = Task.fromJson({'id': 'a', 'project_id': 'p', 'title': 'x'});
    expect(bare.state, 'ready');
    expect(bare.scope, isEmpty);
    expect(bare.sessionId, isNull);
  });

  test('parseScope: one path per line, trimmed, blanks and duplicates dropped, ./ stripped', () {
    expect(parseScope(' src/a \n\n./lib/b.dart\nsrc/a\n  \n'), ['src/a', 'lib/b.dart']);
    expect(parseScope(''), isEmpty);
    expect(scopeText(['a', 'b/c']), 'a\nb/c');
  });

  test('groupByState: board order, empty groups left out', () {
    Task t(String id, String s) => Task(id: id, projectId: 'p', title: id, state: s);
    final g = groupByState([t('a', 'done'), t('b', 'ready'), t('c', 'ready'), t('d', 'review')]);
    expect(g.map((e) => e.$1), ['ready', 'review', 'done']);
    expect(g.first.$2.map((x) => x.id), ['b', 'c']);
  });

  testWidgets('panel groups tasks by state and dispatches a ready one', (tester) async {
    final api = _FakeApi([
      const Task(id: 't1', projectId: 'p1', title: 'Ready one', scope: ['src/a']),
      const Task(id: 't2', projectId: 'p1', title: 'Running one', state: 'running', sessionId: 's_2'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TasksPanel(
          creds: const Creds('http://localhost', 'tok'),
          project: const Project(id: 'p1', path: '/x/p', name: 'proj'),
          api: api,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Ready · 1'), findsOneWidget);
    expect(find.text('Running · 1'), findsOneWidget);
    expect(find.text('Ready one'), findsOneWidget);
    expect(find.text('Scope: src/a'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Dispatch'), findsOneWidget);
    await tester.tap(find.text('Dispatch'));
    await tester.pumpAndSettle();
    expect(api.dispatched, ['t1']);
  });
}
