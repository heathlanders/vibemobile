import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/sessions/domain/task_profile.dart';
import 'package:vibemobile/features/settings/presentation/settings_screen.dart';

void main() {
  test('every task kind has a suggested model', () {
    expect({for (final k in TaskKind.values) k: taskModelHint(k)},
        {TaskKind.plan: 'Opus', TaskKind.implement: 'Sonnet', TaskKind.review: 'Opus', TaskKind.quick: 'Haiku'});
  });
}
