import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/prompts/domain/prompt.dart';

void main() {
  group('extractVars', () {
    test('finds distinct names in first-seen order', () {
      expect(extractVars('Refactor {{file}} for {{goal}} in {{file}}'), ['file', 'goal']);
    });
    test('tolerates inner whitespace', () {
      expect(extractVars('{{ a }} {{b}}'), ['a', 'b']);
    });
    test('no vars → empty', () {
      expect(extractVars('plain text'), isEmpty);
    });
  });

  group('fillTemplate', () {
    test('substitutes provided values', () {
      expect(fillTemplate('Hi {{name}}', {'name': 'boss'}), 'Hi boss');
    });
    test('replaces every occurrence', () {
      expect(fillTemplate('{{x}}-{{x}}', {'x': '7'}), '7-7');
    });
    test('a missing value leaves the placeholder', () {
      expect(fillTemplate('Hi {{name}}', {}), 'Hi {{name}}');
    });
  });

  test('Prompt.fromJson parses tags, scope, and var defaults', () {
    final p = Prompt.fromJson({
      'id': '1',
      'title': 't',
      'body': 'b',
      'tags': 'a, b ,',
      'project_id': null,
      'vars_json': '{"file":"lib/main.dart"}',
    });
    expect(p.tags, ['a', 'b']);
    expect(p.isGlobal, true);
    expect(p.varDefaults['file'], 'lib/main.dart');
  });

  test('templatesOf keeps prompts tagged template, any case', () {
    Prompt p(String id, List<String> tags) => Prompt(id: id, title: id, body: 'b', tags: tags);
    final out = templatesOf([p('a', ['template']), p('b', ['review']), p('c', ['Template', 'x']), p('d', [])]);
    expect(out.map((e) => e.id), ['a', 'c']);
  });
}
