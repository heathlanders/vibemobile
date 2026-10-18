import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/notifications/domain/push_note.dart';
import 'package:vibemobile/features/tasks/data/task_api.dart';
import 'package:vibemobile/features/tasks/domain/merge_item.dart';
import 'package:vibemobile/features/tasks/presentation/merge_approval_screen.dart';

final _tested = 'b' * 40;

Map<String, dynamic> _json({String state = 'awaiting_approval', Object? result, int attempt = 1}) => {
      'id': 'm1',
      'project_id': 'p1',
      'task_id': 't1',
      'session_id': 's1',
      'target': 'main',
      'source_sha': 'c' * 40,
      'target_sha': 'a' * 40,
      'tested_sha': _tested,
      'state': state,
      'attempt': attempt,
      'result': result,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

/// Records requests; answers every call with [body].
class _Recorder extends Interceptor {
  _Recorder(this.body, {this.status = 200});
  final Object? body;
  final int status;
  final calls = <RequestOptions>[];

  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) {
    calls.add(o);
    h.resolve(Response(requestOptions: o, statusCode: status, data: body));
  }
}

(TaskApi, _Recorder) _api(Object? body, {int status = 200}) {
  final rec = _Recorder(body, status: status);
  return (TaskApi(Dio()..interceptors.add(rec)), rec);
}

class _FakeApi extends TaskApi {
  _FakeApi() : super(Dio());
  final approved = <(String, String)>[];

  @override
  Future<MergeItem> approve(String itemId, String sha) async {
    approved.add((itemId, sha));
    return MergeItem.fromJson(_json(state: 'merged'));
  }
}

void main() {
  test('MergeItem.fromJson reads every field and the full result', () {
    final i = MergeItem.fromJson(_json(result: {
      'diffstat': ' a.dart | 2 +-',
      'commits': ['abc fix', 'def more'],
      'untested': false,
      'test_ok': false,
      'test_exit': 1,
      'timed_out': false,
      'output': 'boom',
      'reason': 'red test',
      'notes': 'not synced',
    }));
    expect(i.target, 'main');
    expect(i.testedSha, _tested);
    expect(i.result.commits, ['abc fix', 'def more']);
    expect(i.result.testOk, false);
    expect(i.result.testExit, 1);
    expect(i.result.output, 'boom');
    expect(i.result.reason, 'red test');
    expect(i.result.notes, 'not synced');
  });

  test('MergeItem.fromJson tolerates a missing or empty result; untested parses', () {
    final none = MergeItem.fromJson(_json());
    expect(none.result.commits, isEmpty);
    expect(none.result.untested, false);
    expect(none.result.testOk, isNull);
    expect(none.result.output, '');
    final u = MergeItem.fromJson(_json(result: {'untested': true, 'diffstat': 'x'}));
    expect(u.result.untested, true);
    expect(u.result.testOk, isNull);
  });

  test('canRequeue only for bounced items under 3 attempts', () {
    expect(MergeItem.fromJson(_json(state: 'bounced', attempt: 2)).canRequeue, true);
    expect(MergeItem.fromJson(_json(state: 'bounced', attempt: 3)).canRequeue, false);
    expect(MergeItem.fromJson(_json(attempt: 1)).canRequeue, false);
  });

  test('latestByTask keeps the newest (first) item per task', () {
    final a = MergeItem.fromJson({..._json(state: 'queued'), 'id': 'new'});
    final b = MergeItem.fromJson({..._json(state: 'bounced'), 'id': 'old'});
    expect(latestByTask([a, b])['t1']!.id, 'new');
  });

  test('parseTestCommand splits on whitespace; empty is null', () {
    expect(parseTestCommand('  pnpm   test -- --run '), ['pnpm', 'test', '--', '--run']);
    expect(parseTestCommand('   '), isNull);
    expect(testCommandText(null), '');
  });

  test('API request shapes', () async {
    var (api, rec) = _api(_json());
    await api.approve('m1', _tested);
    expect(rec.calls.single.method, 'POST');
    expect(rec.calls.single.path, '/merge-queue/m1/approve');
    expect(rec.calls.single.data, {'sha': _tested});

    (api, rec) = _api(_json());
    await api.enqueue('t1');
    await api.reject('m1');
    await api.requeue('m1');
    expect(rec.calls.map((c) => '${c.method} ${c.path}'),
        ['POST /tasks/t1/enqueue', 'POST /merge-queue/m1/reject', 'POST /merge-queue/m1/requeue']);

    (api, rec) = _api([_json()]);
    expect((await api.listQueue('p1')).single.id, 'm1');
    expect(rec.calls.single.path, '/projects/p1/merge-queue');

    (api, rec) = _api({'test_command': ['pnpm', 'test']});
    expect(await api.getProjectSettings('p1'), ['pnpm', 'test']);
    expect(await api.putProjectSettings('p1', testCommand: null), ['pnpm', 'test']);
    expect(rec.calls.last.method, 'PUT');
    expect(rec.calls.last.path, '/projects/p1/settings');
    expect(rec.calls.last.data, {'test_command': null});
  });

  test('the daemon error string is surfaced on 4xx', () async {
    final (api, _) = _api({'error': 'the target branch moved: the item was requeued'}, status: 409);
    expect(api.approve('m1', _tested), throwsA(predicate((e) => '$e'.contains('the target branch moved'))));
  });

  test('merge_ready / merge_bounced map to content-free notes that open the session', () {
    final ready = buildNotes('merge_ready', 's1', const {}).single;
    expect(ready.title, 'Merge ready for approval');
    expect(ready.actions, isEmpty);
    expect(NotePayload.decode(ready.payload)!.sessionId, 's1');
    final bounced = buildNotes('merge_bounced', 's1', const {}).single;
    expect(bounced.title, 'Merge bounced');
    expect(bounced.id, isNot(ready.id));
  });

  Future<_FakeApi> pump(WidgetTester tester, MergeItem item) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: MergeApprovalScreen(api: api, item: item)));
    return api;
  }

  testWidgets('approval screen warns when untested and Approve posts the full tested_sha', (tester) async {
    final api = await pump(tester, MergeItem.fromJson(_json(result: {'untested': true, 'diffstat': 'x | 1 +'})));
    expect(find.textContaining('Untested'), findsOneWidget);
    expect(find.text('${'a' * 12}..${'b' * 12}'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(api.approved, [('m1', _tested)]);
  });

  testWidgets('bounced at 3 attempts disables Requeue and explains', (tester) async {
    await pump(tester, MergeItem.fromJson(_json(state: 'bounced', attempt: 3, result: {'reason': 'conflict'})));
    expect(find.text('conflict'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Requeue')).onPressed, isNull);
    expect(find.textContaining('Reset the task'), findsOneWidget);
  });
}
