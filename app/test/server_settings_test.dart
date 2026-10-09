import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/settings/data/server_settings_api.dart';
import 'package:vibemobile/features/settings/presentation/server_settings_screen.dart';

Map<String, dynamic> raw(String key, String type, Object value, Object def, {num? min, num? max, int? maxLen}) => {
      'key': key,
      'type': type,
      'value': value,
      'default': def,
      'isDefault': value == def,
      'min': ?min,
      'max': ?max,
      'maxLen': ?maxLen,
    };

List<Map<String, dynamic>> payload({bool rules = true, String text = 'RULES', num alert = 90, num minFree = 5, num dataGb = 5}) => [
      raw('rules.enabled', 'bool', rules, true),
      raw('rules.text', 'text', text, 'RULES', maxLen: 4000),
      raw('disk.alert_percent', 'int', alert, 90, min: 50, max: 99),
      raw('disk.min_free_gb', 'float', minFree, 5, min: 0, max: 500),
      raw('disk.daemon_data_alert_gb', 'float', dataGb, 5, min: 0, max: 1000),
    ];

ServerSettings parsed(List<Map<String, dynamic>> l) => ServerSettings([for (final m in l) ServerSetting.fromJson(m)]);

/// Records updates; the "server" applies them to a local list so the screen re-renders.
class FakeApi extends ServerSettingsApi {
  FakeApi({this.reject}) : super(Dio());
  final String? reject;
  var state = payload();
  final updates = <Map<String, Object?>>[];

  @override
  Future<ServerSettings> fetch() async => parsed(state);

  @override
  Future<ServerSettings> update(Map<String, Object?> values) async {
    updates.add(values);
    if (reject != null) throw SettingsRejected(reject!);
    state = payload(
      rules: (values['rules.enabled'] as bool?) ?? true,
      text: values.containsKey('rules.text') ? (values['rules.text'] as String? ?? 'RULES') : 'RULES',
      alert: (values['disk.alert_percent'] as num?) ?? 90,
      minFree: (values['disk.min_free_gb'] as num?) ?? 5,
      dataGb: (values['disk.daemon_data_alert_gb'] as num?) ?? 5,
    );
    return parsed(state);
  }
}

void main() {
  group('parseSettingNumber', () {
    final alert = ServerSetting.fromJson(raw('disk.alert_percent', 'int', 90, 90, min: 50, max: 99));
    final free = ServerSetting.fromJson(raw('disk.min_free_gb', 'float', 5, 5, min: 0, max: 500));

    test('accepts in-range values, trims', () {
      expect(parseSettingNumber(' 80 ', alert).value, 80);
      expect(parseSettingNumber('50', alert).value, 50);
      expect(parseSettingNumber('99', alert).value, 99);
      expect(parseSettingNumber('12.5', free).value, 12.5);
      expect(parseSettingNumber('0', free).value, 0);
    });

    test('rejects out-of-range, non-numbers, and fractions for whole-number settings', () {
      expect(parseSettingNumber('49', alert).error, contains('At least'));
      expect(parseSettingNumber('100', alert).error, contains('At most'));
      expect(parseSettingNumber('abc', alert).error, 'Enter a number');
      expect(parseSettingNumber('', alert).error, 'Enter a number');
      expect(parseSettingNumber('90.5', alert).error, 'Whole numbers only');
      expect(parseSettingNumber('-1', free).error, contains('At least'));
      expect(parseSettingNumber('501', free).error, contains('At most'));
    });
  });

  group('ServerSettings', () {
    test('typed getters; missing keys fall back to the daemon defaults', () {
      final s = parsed(payload(rules: false, text: 'x', alert: 80, minFree: 12.5));
      expect([s.rulesEnabled, s.rulesText, s.alertPercent, s.minFreeGb], [false, 'x', 80, 12.5]);
      final empty = ServerSettings(const []);
      expect([empty.rulesEnabled, empty.alertPercent, empty.minFreeGb], [true, 90, 5]);
    });
  });

  group('ServerSettingsApi', () {
    Dio stub(int status, Object? body, List<RequestOptions> seen) => Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        seen.add(o);
        h.resolve(Response(requestOptions: o, statusCode: status, data: body));
      }));

    test('fetch parses the list', () async {
      final seen = <RequestOptions>[];
      final s = await ServerSettingsApi(stub(200, {'settings': payload()}, seen)).fetch();
      expect(s.alertPercent, 90);
      expect(seen.single.path, '/settings');
    });

    test('update PUTs {values: …} (null = reset) and returns the new view', () async {
      final seen = <RequestOptions>[];
      final s = await ServerSettingsApi(stub(200, {'settings': payload(alert: 80)}, seen)).update({'disk.alert_percent': 80, 'rules.text': null});
      expect(s.alertPercent, 80);
      expect(seen.single.method, 'PUT');
      expect(seen.single.data, {'values': {'disk.alert_percent': 80, 'rules.text': null}});
    });

    test('a 400 surfaces the daemon\'s message', () async {
      final api = ServerSettingsApi(stub(400, {'error': 'disk.alert_percent: must be between 50 and 99'}, []));
      await expectLater(api.update({'disk.alert_percent': 10}), throwsA(isA<SettingsRejected>().having((e) => e.message, 'message', contains('between 50 and 99'))));
    });
  });

  group('ServerSettingsScreen', () {
    Future<FakeApi> pump(WidgetTester t, {FakeApi? api}) async {
      final a = api ?? FakeApi();
      await t.pumpWidget(MaterialApp(home: ServerSettingsScreen(creds: const Creds('http://x', 't'), api: a)));
      await t.pumpAndSettle();
      return a;
    }

    testWidgets('shows the current values', (t) async {
      await pump(t);
      expect(find.text('Session rules & storage'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      expect(find.text('5 GB'), findsNWidgets(2), reason: 'min-free guard + daemon-data alert');
      expect(find.text('RULES'), findsOneWidget);
    });

    testWidgets('the switch sends rules.enabled and the screen reflects the server\'s answer', (t) async {
      final api = await pump(t);
      await t.tap(find.byType(Switch));
      await t.pumpAndSettle();
      expect(api.updates, [
        {'rules.enabled': false}
      ]);
      expect(t.widget<Switch>(find.byType(Switch)).value, false);
    });

    testWidgets('alert threshold: out-of-range input is refused locally, a valid one is saved', (t) async {
      final api = await pump(t);
      await t.tap(find.text('Warn when a disk is fuller than'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '150');
      await t.tap(find.text('Save'));
      await t.pump();
      expect(find.text('At most 99'), findsOneWidget);
      expect(api.updates, isEmpty, reason: 'nothing sent for an invalid value');
      await t.enterText(find.byType(TextField), '80');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(api.updates, [
        {'disk.alert_percent': 80}
      ]);
      expect(find.text('80%'), findsOneWidget);
    });

    testWidgets('free-space guard of 0 reads "off"', (t) async {
      final api = await pump(t);
      await t.tap(find.text('Refuse new sessions below'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '0');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(api.updates.single, {'disk.min_free_gb': 0});
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('daemon-data alert: saves a number, 0 reads "off"', (t) async {
      final api = await pump(t);
      expect(find.text('5 GB'), findsNWidgets(2), reason: 'min-free and daemon-data both default to 5');
      await t.tap(find.text('Warn when daemon data passes'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '0');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(api.updates.single, {'disk.daemon_data_alert_gb': 0});
      expect(find.text('off'), findsOneWidget);
    });

    testWidgets('editing the rules text saves the new text; Reset sends null', (t) async {
      final api = await pump(t);
      await t.tap(find.text('Rules text'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Only use /data.');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(api.updates.last, {'rules.text': 'Only use /data.'});

      api.state = payload(text: 'Only use /data.');
      await t.pumpWidget(MaterialApp(home: ServerSettingsScreen(creds: const Creds('http://x', 't'), api: api)));
      await t.pumpAndSettle();
      await t.tap(find.text('Rules text'));
      await t.pumpAndSettle();
      await t.tap(find.text('Reset'));
      await t.pumpAndSettle();
      expect(api.updates.last, {'rules.text': null});
    });

    testWidgets('a daemon rejection is shown and the displayed values do not change', (t) async {
      final api = await pump(t, api: FakeApi(reject: 'disk.alert_percent: must be between 50 and 99'));
      await t.tap(find.text('Warn when a disk is fuller than'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '80');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.textContaining('must be between 50 and 99'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      expect(api.updates.length, 1);
    });
  });
}
