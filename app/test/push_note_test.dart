import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/notifications/domain/push_note.dart';

Map<String, dynamic> _question({bool multi = false, int n = 1}) => {
      't': 'user_dialog',
      'dialogId': 'd1',
      'dialogKind': 'ask_user_question',
      'payload': {
        'questions': [
          for (var i = 0; i < n; i++)
            {
              'question': 'Which DB?',
              'multiSelect': multi,
              'options': [
                {'label': 'SQLite'},
                {'label': 'Postgres'},
                {'label': 'MySQL'},
                {'label': 'Mongo'},
              ],
            },
        ],
      },
    };

void main() {
  test('stableNoteId is deterministic, 31-bit, and key-sensitive', () {
    expect(stableNoteId('abc'), stableNoteId('abc'));
    expect(stableNoteId('abc'), isNot(stableNoteId('abd')));
    expect(stableNoteId('x' * 500), inInclusiveRange(0, 0x7fffffff));
  });

  test('permission → Allow/Deny with the Bash command in the body', () {
    final notes = buildNotes('permission', 's1', {
      'title': 'fix build',
      'permissions': [
        {
          't': 'permission_request',
          'toolUseID': 'tu1',
          'toolName': 'Bash',
          'input': {'command': 'rm -rf build/', 'description': 'clean'},
        },
      ],
      'dialogs': [],
    });
    expect(notes, hasLength(1));
    final n = notes.single;
    expect(n.title, 'fix build needs approval');
    expect(n.body, 'Bash: rm -rf build/');
    expect(n.actions.map((a) => a.$1), ['allow', 'deny']);
    expect(n.id, stableNoteId('tu1'));
    expect(n.prompt, isTrue);

    final p = NotePayload.decode(n.payload)!;
    final a = answerFor(p, 'allow') as PermissionAnswer;
    expect((a.toolUseID, a.allow), ('tu1', true));
    expect((answerFor(p, 'deny') as PermissionAnswer).allow, isFalse);
    expect(answerFor(p, null), isNull, reason: 'body tap is not an answer');
  });

  test('long input is flattened and truncated', () {
    final n = buildNotes('permission', 's1', {
      'permissions': [
        {'toolUseID': 't', 'toolName': 'Bash', 'input': {'command': 'echo\n${'a' * 400}'}},
      ],
    }).single;
    expect(n.title, 'Claude needs approval', reason: 'no title → Claude');
    expect(n.body.length, lessThanOrEqualTo(160));
    expect(n.body, isNot(contains('\n')));
    expect(n.body, endsWith('…'));
  });

  test('single single-select question → up to 3 option buttons that answer it', () {
    final n = buildNotes('question', 's1', {'dialogs': [_question()]}).single;
    expect(n.body, 'Which DB?');
    expect(n.actions.map((a) => a.$2), ['SQLite', 'Postgres', 'MySQL']);

    final a = answerFor(NotePayload.decode(n.payload)!, 'opt:1') as DialogAnswer;
    expect(a.dialogId, 'd1');
    expect(a.result['answers'], {'Which DB?': 'Postgres'});
    expect(a.result['questions'], isA<List<dynamic>>());
    expect(answerFor(NotePayload.decode(n.payload)!, 'opt:9'), isNull);
  });

  test('multi-select or multi-question → no buttons (tap opens the session)', () {
    expect(buildNotes('question', 's1', {'dialogs': [_question(multi: true)]}).single.actions, isEmpty);
    final multi = buildNotes('question', 's1', {'dialogs': [_question(n: 2)]}).single;
    expect(multi.actions, isEmpty);
    expect(answerFor(NotePayload.decode(multi.payload)!, 'opt:0'), isNull);
  });

  test('nothing pending → no notification; done always shows', () {
    expect(buildNotes('permission', 's1', {'title': 'x', 'permissions': [], 'dialogs': []}), isEmpty);
    final done = buildNotes('done', 's1', {'title': 'x', 'permissions': [], 'dialogs': []}).single;
    expect(done.title, 'x finished');
    expect(done.actions, isEmpty);
    expect(done.prompt, isFalse);
    expect(NotePayload.decode(done.payload)!.sessionId, 's1');
  });

  test('NotePayload.decode rejects junk', () {
    expect(NotePayload.decode(null), isNull);
    expect(NotePayload.decode('not json'), isNull);
    expect(NotePayload.decode('{"k":"done"}'), isNull);
  });

  test('CLI session pushes → one tap-to-open note per session, no buttons', () {
    final perm = buildNotes('cli_permission', 's1', {'title': 'fix build', 'permissions': [], 'dialogs': []}).single;
    expect(perm.title, 'fix build needs approval');
    expect(perm.actions, isEmpty);
    expect(perm.prompt, isTrue);
    expect(NotePayload.decode(perm.payload)!.sessionId, 's1');

    final waiting = buildNotes('cli_waiting', 's1', {'title': null}).single;
    expect(waiting.title, 'Claude is waiting');
    expect(waiting.prompt, isFalse);
    expect(waiting.id, perm.id, reason: 'newer state replaces the older one');

    expect(buildNotes('cli_question', 's1', {}).single.title, 'Claude has a question');
  });

  test('usage reset note: content-free, stable id, tap-only', () {
    final n = usageResetNote();
    expect(n.id, stableNoteId('usage_reset'));
    expect(n.actions, isEmpty);
    expect(n.prompt, isFalse);
    expect(NotePayload.decode(n.payload)?.sessionId, '');
  });
}
