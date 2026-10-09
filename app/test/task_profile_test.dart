import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/features/sessions/data/task_model_prefs.dart';
import 'package:vibemobile/features/sessions/domain/task_profile.dart';

void main() {
  test('suggestTask: keywords, most specific first', () {
    expect(suggestTask('Review the plan in PLAN.md'), TaskKind.review, reason: 'review beats plan');
    expect(suggestTask('Please audit auth.ts for token leaks'), TaskKind.review);
    expect(suggestTask('Design an approach for offline sync'), TaskKind.plan);
    expect(suggestTask('Explain what this regex does'), TaskKind.quick);
    expect(suggestTask('Fix the failing tests in spend.test.ts'), TaskKind.implement);
    expect(suggestTask('Refactor the socket layer'), TaskKind.implement);
    expect(suggestTask('Is the daemon on Node 18?'), TaskKind.quick, reason: 'short question');
    expect(suggestTask('Hello there'), isNull);
    expect(suggestTask('   '), isNull);
    expect(suggestTask('address the reviewer comments'), isNull, reason: 'word boundaries: no "add"/"review" inside words');
  });

  test('TaskModelPrefs round-trips and clears', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await TaskModelPrefs.get(TaskKind.review), isNull);
    await TaskModelPrefs.set(TaskKind.review, (id: 'claude-opus-4-8', label: 'Opus'));
    expect(await TaskModelPrefs.get(TaskKind.review), (id: 'claude-opus-4-8', label: 'Opus'));
    expect(await TaskModelPrefs.get(TaskKind.quick), isNull);
    await TaskModelPrefs.set(TaskKind.review, null);
    expect(await TaskModelPrefs.get(TaskKind.review), isNull);
  });
}
