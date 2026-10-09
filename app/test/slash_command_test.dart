import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/slash_command.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

ChatSessionController controller() => ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

const all = [
  SlashCommandInfo(name: 'simplify', description: 'Review the changed code', hint: '[<target>]'),
  SlashCommandInfo(name: 'schedule', description: 'Create scheduled cloud agents'),
  SlashCommandInfo(name: 'stripe:test-cards', description: '(stripe) Display Stripe test card numbers'),
  SlashCommandInfo(name: 'code-review', description: 'Review a PR'),
  SlashCommandInfo(name: 'files', description: 'a skill that collides with the app\'s /files'),
];

List<String> names(List<SlashCommandInfo> l) => [for (final c in l) c.name];

void main() {
  group('SlashCommandInfo', () {
    test('parses a frame entry; subtitle joins hint and description', () {
      final c = SlashCommandInfo.tryFromJson({'name': 'simplify', 'description': 'Review', 'hint': '<f>'})!;
      expect([c.name, c.description, c.hint], ['simplify', 'Review', '<f>']);
      expect(c.subtitle, '<f> — Review');
      expect(const SlashCommandInfo(name: 'x', description: 'd').subtitle, 'd');
      expect(const SlashCommandInfo(name: 'x').subtitle, '');
    });

    test('malformed entries become null, wrong-typed fields become empty — never a throw', () {
      for (final bad in [null, 5, 'x', [], <String, dynamic>{}, {'name': 3}, {'name': ''}]) {
        expect(SlashCommandInfo.tryFromJson(bad), isNull, reason: '$bad');
      }
      final c = SlashCommandInfo.tryFromJson({'name': 'ok', 'description': 5, 'hint': []})!;
      expect([c.description, c.hint], ['', '']);
    });
  });

  group('matchCommands', () {
    test('empty query lists commands (capped); a prefix ranks before a substring', () {
      expect(names(matchCommands(all, '')), names(all));
      expect(names(matchCommands(all, '', limit: 2)).length, 2);
      // "s" → names starting with s first (simplify, schedule, stripe…), then others that merely contain/mention it
      final r = names(matchCommands(all, 's'));
      expect(r.take(3), ['simplify', 'schedule', 'stripe:test-cards']);
    });

    test('contains matches the name or the description, case-insensitively', () {
      expect(names(matchCommands(all, 'REVIEW')).toSet(), {'simplify', 'code-review'}, reason: 'case-insensitive; name or description');
      expect(names(matchCommands(all, 'stripe')), ['stripe:test-cards']);
      expect(matchCommands(all, 'zzz'), isEmpty);
    });

    test('names the app already handles locally are excluded', () {
      expect(names(matchCommands(all, 'fi', exclude: {'files'})), isNot(contains('files')));
      expect(names(matchCommands(all, '', exclude: {'files', 'simplify'})), isNot(containsAll(['files', 'simplify'])));
    });

    test('whitespace around the query is ignored', () {
      expect(names(matchCommands(all, '  simp ')), ['simplify']);
    });
  });

  group('controller', () {
    test('a commands frame fills the list; bad entries are skipped', () {
      final c = controller();
      expect(c.slashCommands, isEmpty);
      c.applyFrame({
        't': 'commands',
        'commands': [
          {'name': 'simplify', 'description': 'Review', 'hint': ''},
          5,
          {'name': ''},
          {'name': 'deploy'},
        ],
      });
      expect(names(c.slashCommands), ['simplify', 'deploy']);
    });

    test('a later frame replaces the list (commands_changed); a non-list is ignored safely', () {
      final c = controller();
      c.applyFrame({'t': 'commands', 'commands': [{'name': 'a'}]});
      c.applyFrame({'t': 'commands', 'commands': [{'name': 'b'}, {'name': 'c'}]});
      expect(names(c.slashCommands), ['b', 'c']);
      c.applyFrame({'t': 'commands', 'commands': 'oops'});
      expect(c.slashCommands, isEmpty);
    });
  });
}
