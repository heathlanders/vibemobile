import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/schedules/data/schedule_api.dart';
import 'package:vibemobile/features/schedules/domain/schedule_info.dart';
import 'package:vibemobile/features/schedules/presentation/schedule_edit_screen.dart';
import 'package:vibemobile/features/schedules/presentation/schedules_screen.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

Map<String, dynamic> raw({
  String id = 'sch1',
  String title = 'Morning check',
  String kind = 'daily',
  String? time = '09:00',
  List<int>? days,
  String? runAt,
  String mode = 'ask',
  bool enabled = true,
  String? next = '2026-10-08T09:00:00.000Z',
  String? lastStatus,
  String? lastSession,
}) =>
    {
      'id': id, 'projectId': 'p', 'projectName': 'vibemobile', 'title': title, 'prompt': 'Summarize CI', 'mode': mode, 'model': null,
      'kind': kind, 'time': time, 'days': days, 'runAt': runAt, 'enabled': enabled, 'nextRunAt': next,
      'lastRunAt': null, 'lastStatus': lastStatus, 'lastSessionId': lastSession,
    };

ScheduleInfo info([Map<String, dynamic>? m]) => ScheduleInfo.tryFromJson(m ?? raw())!;

class FakeApi extends ScheduleApi {
  FakeApi(this.rows, {this.offset = 0}) : super(Dio());
  List<Map<String, dynamic>> rows;
  final int offset;
  final calls = <String>[];
  Map<String, Object?>? lastBody;
  String? failWith;

  @override
  Future<SchedulesData> list() async => SchedulesData(schedules: [for (final r in rows) info(r)], tz: 'UTC', offsetMin: offset);
  @override
  Future<ScheduleInfo> create(Map<String, Object?> body) async {
    calls.add('create');
    lastBody = body;
    if (failWith != null) throw ScheduleRejected(failWith!);
    return info();
  }

  @override
  Future<ScheduleInfo> update(String id, Map<String, Object?> body) async {
    calls.add('update $id');
    lastBody = body;
    if (body.containsKey('enabled')) rows = [for (final r in rows) if (r['id'] == id) {...r, 'enabled': body['enabled']} else r];
    return info();
  }

  @override
  Future<void> delete(String id) async {
    calls.add('delete $id');
    rows = [for (final r in rows) if (r['id'] != id) r];
  }

  @override
  Future<String> runNow(String id) async {
    calls.add('run $id');
    return 's_new';
  }
}

void main() {
  group('server-local time maths', () {
    test('toServerLocal / fromServerLocal are inverses, for + and − offsets', () {
      for (final off in [0, 120, -300, 330]) {
        final instant = DateTime.utc(2026, 10, 8, 9, 0);
        final local = toServerLocal(instant, off);
        expect(fromServerLocal(local.year, local.month, local.day, local.hour, local.minute, off), instant, reason: 'offset $off');
      }
      // 09:00 on the server's wall clock at UTC+2 is 07:00 UTC
      expect(fromServerLocal(2026, 10, 8, 9, 0, 120), DateTime.utc(2026, 10, 8, 7, 0));
    });

    test('formatServerTime shows the server\'s wall clock', () {
      expect(formatServerTime(DateTime.utc(2026, 10, 8, 7, 5), 120), 'Thu 8 Oct 09:05');
      expect(formatServerTime(DateTime.utc(2026, 10, 11, 23, 30), 0), 'Sun 11 Oct 23:30');
    });

    test('daysLabel', () {
      expect(daysLabel(null), 'Every day');
      expect(daysLabel([0, 1, 2, 3, 4, 5, 6]), 'Every day');
      expect(daysLabel([1, 2, 3, 4, 5]), 'Mon–Fri');
      expect(daysLabel([5, 4, 3, 2, 1]), 'Mon–Fri', reason: 'order-insensitive');
      expect(daysLabel([0, 6]), 'Weekends');
      expect(daysLabel([3, 1]), 'Mon, Wed');
    });
  });

  group('ScheduleInfo', () {
    test('parses and labels', () {
      final s = info(raw(days: [1, 2, 3, 4, 5]));
      expect(s.whenLabel(0), 'Mon–Fri at 09:00');
      expect(s.enabled, true);
      expect(s.nextRunAt, DateTime.utc(2026, 10, 8, 9));
      expect(info(raw(kind: 'once', time: null, runAt: '2026-10-08T07:00:00.000Z')).whenLabel(120), 'Once · Thu 8 Oct 09:00');
    });

    test('needsAttention for anything other than a clean start', () {
      expect(info(raw(lastStatus: 'started')).needsAttention, false);
      expect(info(raw()).needsAttention, false);
      for (final s in ['missed', 'waiting: low disk space', 'skipped: the previous run is still going', 'failed: project is gone']) {
        expect(info(raw(lastStatus: s)).needsAttention, true, reason: s);
      }
    });

    test('isAuto, and junk never throws', () {
      expect(info(raw(mode: 'auto')).isAuto, true);
      for (final bad in [null, 5, 'x', [], <String, dynamic>{}, {'id': 1}, {'id': 'a', 'projectId': 'p'}]) {
        expect(ScheduleInfo.tryFromJson(bad), isNull, reason: '$bad');
      }
      final odd = ScheduleInfo.tryFromJson({'id': 'a', 'projectId': 'p', 'title': 't', 'days': ['x', 3], 'nextRunAt': 'garbage', 'enabled': 'yes'})!;
      expect([odd.days, odd.nextRunAt, odd.enabled], [[3], null, false]);
    });
  });

  group('buildScheduleBody', () {
    Map<String, Object?> body({bool daily = true, Set<int> days = const {}, DateTime? once, String? projectId = 'p', int offset = 0, String mode = 'ask'}) =>
        buildScheduleBody(projectId: projectId, title: '  Check  ', prompt: 'Do it', mode: mode, daily: daily, time: const TimeOfDay(hour: 7, minute: 5), days: days, onceDate: once, offsetMin: offset);

    test('daily: zero-padded time, trimmed title, no days = every day (null)', () {
      final b = body();
      expect(b, {'projectId': 'p', 'title': 'Check', 'prompt': 'Do it', 'mode': 'ask', 'kind': 'daily', 'time': '07:05', 'days': null});
    });

    test('daily: chosen days are sent sorted; all seven means every day', () {
      expect(body(days: {5, 1, 3})['days'], [1, 3, 5]);
      expect(body(days: {0, 1, 2, 3, 4, 5, 6})['days'], isNull);
    });

    test('once: the server-local wall time becomes the right UTC instant', () {
      final b = body(daily: false, once: DateTime(2026, 10, 8), offset: 120);
      expect(b['kind'], 'once');
      expect(b['runAt'], '2026-10-08T05:05:00.000Z'); // 07:05 at UTC+2
      expect(b.containsKey('time'), false);
      expect(b.containsKey('days'), false);
    });

    test('a patch omits the project', () {
      expect(body(projectId: null).containsKey('projectId'), false);
    });
  });

  group('ScheduleApi', () {
    Dio stub(int status, Object? data, List<RequestOptions> seen) => Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        seen.add(o);
        h.resolve(Response(requestOptions: o, statusCode: status, data: data));
      }));

    test('list parses schedules, zone and offset', () async {
      final d = await ScheduleApi(stub(200, {'tz': 'Europe/Berlin', 'offsetMin': 120, 'schedules': [raw(), 5]}, [])).list();
      expect([d.tz, d.offsetMin, d.schedules.length], ['Europe/Berlin', 120, 1]);
    });

    test('a refusal surfaces the daemon\'s message', () async {
      final api = ScheduleApi(stub(400, {'error': 'time: HH:MM (24 h)'}, []));
      await expectLater(api.create({'x': 1}), throwsA(isA<ScheduleRejected>().having((e) => e.message, 'message', contains('HH:MM'))));
      await expectLater(ScheduleApi(stub(429, {'error': 'too many live sessions'}, [])).runNow('x'), throwsA(isA<ScheduleRejected>().having((e) => e.message, 'm', contains('too many'))));
    });

    test('runNow returns the new session id; delete hits the right route', () async {
      final seen = <RequestOptions>[];
      expect(await ScheduleApi(stub(201, {'sessionId': 's_9'}, seen)).runNow('sch1'), 's_9');
      expect(seen.single.path, '/schedules/sch1/run');
      final seen2 = <RequestOptions>[];
      await ScheduleApi(stub(204, null, seen2)).delete('sch1');
      expect([seen2.single.method, seen2.single.path], ['DELETE', '/schedules/sch1']);
    });
  });

  group('SchedulesScreen', () {
    Future<FakeApi> pump(WidgetTester t, List<Map<String, dynamic>> rows, {int offset = 0}) async {
      final api = FakeApi(rows, offset: offset);
      await t.pumpWidget(MaterialApp(
        home: SchedulesScreen(
          creds: const Creds('http://x', 't'),
          api: api,
          loadProjects: () async => [const Project(id: 'p', path: '/p', name: 'vibemobile')],
          openSession: (ctx, id) async => api.calls.add('open $id'),
        ),
      ));
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('empty state, and the honest explanation of unattended runs', (t) async {
      await pump(t, []);
      expect(find.text('No scheduled tasks yet.'), findsOneWidget);
      expect(find.textContaining('waits for your approval'), findsOneWidget);
    });

    testWidgets('a row shows project, schedule, next run and the last outcome; Auto is flagged', (t) async {
      await pump(t, [raw(days: [1, 2, 3, 4, 5], mode: 'auto', lastStatus: 'waiting: low disk space')], offset: 120);
      expect(find.textContaining('vibemobile · Mon–Fri at 09:00'), findsOneWidget);
      expect(find.textContaining('Next: Thu 8 Oct 11:00'), findsOneWidget, reason: '09:00Z shown in server time (UTC+2)');
      expect(find.textContaining('Last: waiting: low disk space'), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);
    });

    testWidgets('the switch pauses a task; a paused one says so', (t) async {
      final api = await pump(t, [raw()]);
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(api.calls, ['update sch1']);
      expect(api.lastBody, {'enabled': false});
      expect(find.textContaining('Paused'), findsOneWidget);
    });

    testWidgets('Run now / Open last run / Delete (confirmed)', (t) async {
      final api = await pump(t, [raw(lastSession: 's_prev')]);
      Future<void> pick(String item) async {
        await t.tap(find.byTooltip('Actions'));
        await t.pumpAndSettle();
        await t.tap(find.text(item));
        await t.pumpAndSettle();
      }

      await pick('Run now');
      expect(api.calls, contains('run sch1'));
      await pick('Open last run');
      expect(api.calls, contains('open s_prev'));
      await pick('Delete');
      expect(find.textContaining('will stop running'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(api.calls.where((c) => c.startsWith('delete')), isEmpty);
      await pick('Delete');
      await t.tap(find.text('Delete').last);
      await t.pumpAndSettle();
      expect(api.calls, contains('delete sch1'));
      expect(find.text('No scheduled tasks yet.'), findsOneWidget);
    });

    testWidgets('no "Open last run" before the first run', (t) async {
      await pump(t, [raw()]);
      await t.tap(find.byTooltip('Actions'));
      await t.pumpAndSettle();
      expect(find.text('Open last run'), findsNothing);
    });
  });

  group('ScheduleEditScreen', () {
    Future<FakeApi> pump(WidgetTester t, {ScheduleInfo? existing}) async {
      await t.binding.setSurfaceSize(const Size(800, 1600)); // the form is a lazy list: build it all
      addTearDown(() => t.binding.setSurfaceSize(null));
      final api = FakeApi([]);
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<bool>(
                builder: (_) => ScheduleEditScreen(
                  api: api,
                  loadProjects: () async => [const Project(id: 'p', path: '/p', name: 'vibemobile')],
                  offsetMin: 0,
                  tz: 'UTC',
                  existing: existing,
                ),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return api;
    }

    testWidgets('Save stays disabled until name and prompt are filled; then creates with the safe defaults', (t) async {
      final api = await pump(t);
      TextButton save() => t.widget<TextButton>(find.widgetWithText(TextButton, 'Save'));
      expect(save().onPressed, isNull);
      await t.enterText(find.widgetWithText(TextField, 'Name'), 'Nightly');
      await t.enterText(find.widgetWithText(TextField, 'Prompt'), 'Check CI');
      await t.pump();
      expect(save().onPressed, isNotNull);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(api.calls, ['create']);
      expect(api.lastBody!['mode'], 'ask');
      expect(api.lastBody!['kind'], 'daily');
      expect(api.lastBody!['time'], '09:00');
      expect(api.lastBody!['projectId'], 'p');
    });

    testWidgets('choosing Auto asks for confirmation; "Keep Ask" saves nothing', (t) async {
      final api = await pump(t);
      await t.enterText(find.widgetWithText(TextField, 'Name'), 'Risky');
      await t.enterText(find.widgetWithText(TextField, 'Prompt'), 'Do things');
      await t.tap(find.text('Auto'));
      await t.pump();
      expect(find.textContaining('runs tools by itself'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Run without asking?'), findsOneWidget);
      await t.tap(find.text('Keep Ask'));
      await t.pumpAndSettle();
      expect(api.calls, isEmpty);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      await t.tap(find.text('Use Auto'));
      await t.pumpAndSettle();
      expect(api.lastBody!['mode'], 'auto');
    });

    testWidgets('editing: the project is fixed, the patch carries no projectId, Auto already set needs no re-confirm', (t) async {
      final api = await pump(t, existing: info(raw(mode: 'auto')));
      expect(find.widgetWithText(InputDecorator, 'vibemobile'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Run without asking?'), findsNothing);
      expect(api.calls, ['update sch1']);
      expect(api.lastBody!.containsKey('projectId'), false);
    });

    testWidgets('a daemon refusal is shown and the screen stays', (t) async {
      final api = await pump(t);
      api.failWith = 'at most 50 schedules';
      await t.enterText(find.widgetWithText(TextField, 'Name'), 'x');
      await t.enterText(find.widgetWithText(TextField, 'Prompt'), 'y');
      await t.pump();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('at most 50 schedules'), findsOneWidget);
      expect(find.text('New scheduled task'), findsOneWidget);
    });
  });
}
