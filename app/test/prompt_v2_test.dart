import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/prompts/domain/prompt.dart';

void main() {
  test('Prompt parses use_count (defaults to 0)', () {
    expect(Prompt.fromJson({'id': 'a', 'title': 't', 'body': 'b', 'use_count': 4}).useCount, 4);
    expect(Prompt.fromJson({'id': 'a', 'title': 't', 'body': 'b'}).useCount, 0);
  });

  test('PromptHistoryItem parses a history row', () {
    final h = PromptHistoryItem.fromJson({'text': 'run tests', 'times': 3, 'last_ts': '2026-10-01T00:00:00Z', 'project': 'alpha'});
    expect((h.text, h.times, h.project), ('run tests', 3, 'alpha'));
    expect(PromptHistoryItem.fromJson({'text': 'x'}).times, 1);
  });
}
