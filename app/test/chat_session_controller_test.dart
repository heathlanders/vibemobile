import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

ChatSessionController controller() =>
    ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

void main() {
  test('deltas grow one streaming assistant bubble; assistant finalizes it', () {
    final c = controller();
    c.applyFrame({'t': 'delta', 'text': 'Hel'});
    c.applyFrame({'t': 'delta', 'text': 'lo'});
    expect(c.messages.length, 1);
    expect(c.messages.single.role, ChatRole.assistant);
    expect(c.messages.single.text, 'Hello');
    expect(c.messages.single.streaming, true);

    c.applyFrame({'t': 'assistant', 'text': 'Hello'});
    expect(c.messages.length, 1, reason: 'finalizes the same bubble, no duplicate');
    expect(c.messages.single.streaming, false);
  });

  test('dialog_closed withdraws the matching question card only (ADR 0012)', () {
    final c = controller();
    c.applyFrame({
      't': 'user_dialog',
      'dialogId': 'q1',
      'dialogKind': 'ask_user_question',
      'payload': {
        'questions': [
          {'question': 'Which pet?', 'options': [{'label': 'Cat'}, {'label': 'Dog'}]}
        ]
      },
    });
    c.applyFrame({'t': 'dialog_closed', 'dialogId': 'other'});
    expect(c.pendingDialog, isNotNull);
    c.applyFrame({'t': 'dialog_closed', 'dialogId': 'q1'});
    expect(c.pendingDialog, isNull);
  });

  test('tool_use adds a tool entry', () {
    final c = controller();
    c.applyFrame({'t': 'tool_use', 'id': 'tu1', 'name': 'Read', 'input': {'file': 'README'}});
    expect(c.messages.single.role, ChatRole.tool);
    expect(c.messages.single.toolName, 'Read');
  });

  test('permission_request sets pending; respond clears it', () {
    final c = controller();
    c.applyFrame({'t': 'permission_request', 'toolUseID': 'tu1', 'toolName': 'Bash', 'title': 'Run ls?'});
    expect(c.pendingPermission, isNotNull);
    expect(c.pendingPermission!.toolName, 'Bash');
    c.respondPermission(false); // socket is null (no connect) — just clears state
    expect(c.pendingPermission, isNull);
  });

  test('permission_closed withdraws the matching approval card only (proposal 58)', () {
    final c = controller();
    c.applyFrame({'t': 'permission_request', 'toolUseID': 'tu1', 'toolName': 'Bash'});
    c.applyFrame({'t': 'permission_closed', 'toolUseID': 'other'});
    expect(c.pendingPermission, isNotNull);
    c.applyFrame({'t': 'permission_closed', 'toolUseID': 'tu1'});
    expect(c.pendingPermission, isNull);
  });

  test('user_turn from another device adds the bubble with its row id (proposal 58)', () {
    final c = controller();
    c.applyFrame({'t': 'user_turn', 'text': 'hi', 'messageId': 'm1', 'images': ['a1'], 'ts': '2026-10-16T18:00:00Z'});
    final m = c.messages.single;
    expect(m.role, ChatRole.user);
    expect(m.text, 'hi');
    expect(m.serverId, 'm1');
    expect(m.images, ['a1']);
  });

  test('permission_request carries an optional diffPreview (proposal 02)', () {
    final c = controller();
    c.applyFrame({
      't': 'permission_request',
      'toolUseID': 'tu2',
      'toolName': 'Edit',
      'input': {'file_path': '/proj/lib/a.dart'},
      'diffPreview': {
        'relPath': 'lib/a.dart',
        'diff': '@@ -1,1 +1,1 @@\n-one\n+two',
        'adds': 1,
        'dels': 1,
        'truncated': true,
      },
    });
    final p = c.pendingPermission!.diffPreview!;
    expect(p.relPath, 'lib/a.dart');
    expect(p.adds, 1);
    expect(p.dels, 1);
    expect(p.truncated, true);
    expect(p.diff, contains('+two'));
  });

  test('a permission_request without diffPreview parses to null (Bash, old daemon)', () {
    final c = controller();
    c.applyFrame({'t': 'permission_request', 'toolUseID': 'tu3', 'toolName': 'Bash'});
    expect(c.pendingPermission!.diffPreview, isNull);
  });

  test('history rebuilds the transcript (text + tool rows)', () {
    final c = controller();
    c.applyFrame({'t': 'assistant', 'text': 'stale'}); // gets cleared by history
    c.applyFrame({
      't': 'history',
      'messages': [
        {'role': 'user', 'content': 'hi', 'tool_json': null},
        {'role': 'assistant', 'content': 'hello', 'tool_json': null},
        {'role': 'tool', 'content': null, 'tool_json': jsonEncode({'name': 'Read', 'input': {}})},
        {'role': 'result', 'content': null, 'tool_json': '{}'}, // result has no bubble
      ],
    });
    final roles = c.messages.map((m) => m.role).toList();
    expect(roles, [ChatRole.user, ChatRole.assistant, ChatRole.tool]);
    expect(c.messages[2].toolName, 'Read');
  });

  test('history replays a user image turn as image refs', () {
    final c = controller();
    c.applyFrame({
      't': 'history',
      'messages': [
        {
          'role': 'user',
          'content': 'look at this',
          'tool_json': null,
          'images': [
            {'id': 'a_abc123', 'mediaType': 'image/png'},
          ],
        },
      ],
    });
    expect(c.messages.single.role, ChatRole.user);
    expect(c.messages.single.text, 'look at this');
    expect(c.messages.single.images, ['a_abc123']);
  });

  test('permission_request carries displayName (proposal 08)', () {
    final c = controller();
    c.applyFrame({
      't': 'permission_request',
      'toolUseID': 'tu1',
      'toolName': 'Bash',
      'displayName': 'Run shell command',
      'title': 'Allow Bash?',
      'description': 'ls -la',
    });
    expect(c.pendingPermission!.displayName, 'Run shell command');
    expect(c.pendingPermission!.description, 'ls -la');
  });

  test('resendUser supersedes the original and appends a verbatim turn (proposal 11)', () {
    final c = controller();
    c.sendUser('frist'); // typo
    final original = c.messages.single;
    expect(original.superseded, false);

    c.resendUser(original);
    expect(original.superseded, true);
    expect(c.messages.length, 2, reason: 'appends a fresh turn, no history rewrite');
    expect(c.messages.last.text, 'frist');
    expect(c.messages.last.superseded, false);
  });

  test('title frame sets the display title and notifies (ADR 0009)', () {
    final c = controller();
    var notified = 0;
    c.addListener(() => notified++);
    expect(c.title, isNull);
    c.applyFrame({'t': 'title', 'title': 'vibemobile · Auto-name chat sessions', 'auto': true});
    expect(c.title, 'vibemobile · Auto-name chat sessions');
    expect(notified, 1);
  });

  test('result frame updates session cost and clears busy (proposals 03, 09)', () {
    final c = controller();
    c.sendUser('hi'); // socket null, but busy flips true
    expect(c.busy, true);
    c.applyFrame({'t': 'result', 'subtype': 'success', 'cost': 0.01, 'sessionCost': 0.42});
    expect(c.busy, false);
    expect(c.sessionCost, 0.42);
  });

  test('tool_result attaches to its tool chip by id (proposal 07)', () {
    final c = controller();
    c.applyFrame({'t': 'tool_use', 'id': 'tu1', 'name': 'Read', 'input': {'file': 'README'}});
    c.applyFrame({'t': 'tool_result', 'toolUseID': 'tu1', 'content': 'file body', 'isError': false});
    final tool = c.messages.single;
    expect(tool.toolUseId, 'tu1');
    expect(tool.toolResult, 'file body');
    expect(tool.toolResultIsError, false);
  });

  test('history replays a tool row with its folded result (proposal 07)', () {
    final c = controller();
    c.applyFrame({
      't': 'history',
      'messages': [
        {
          'role': 'tool',
          'content': null,
          'tool_json': jsonEncode({'id': 'tu9', 'name': 'Bash', 'input': {}, 'result': 'done', 'isError': true}),
        },
      ],
    });
    final tool = c.messages.single;
    expect(tool.toolName, 'Bash');
    expect(tool.toolResult, 'done');
    expect(tool.toolResultIsError, true);
  });

  test('tool_result images land on the tool row, live and on history replay (proposal 33)', () {
    final c = controller();
    c.applyFrame({'t': 'tool_use', 'id': 'tu1', 'name': 'Read', 'input': {}});
    expect(c.messages.single.images, isEmpty);
    c.applyFrame({'t': 'tool_result', 'toolUseID': 'tu1', 'content': '', 'isError': false, 'images': ['a_1']});
    expect(c.messages.single.images, ['a_1']);

    c.applyFrame({
      't': 'history',
      'messages': [
        {
          'role': 'tool',
          'content': null,
          'tool_json': jsonEncode({'id': 'tu1', 'name': 'Read', 'input': {}, 'result': '', 'images': ['a_1', 'a_2']}),
        },
      ],
    });
    expect(c.messages.single.images, ['a_1', 'a_2']);
    // Survives the offline transcript cache round-trip.
    expect(ChatMessage.fromJson(c.messages.single.toJson()).images, ['a_1', 'a_2']);
  });

  test('error frame surfaces an error message', () {
    final c = controller();
    c.applyFrame({'t': 'error', 'message': 'login expired'});
    expect(c.messages.single.role, ChatRole.error);
    expect(c.messages.single.text, 'login expired');
  });

  test('mirroring a CLI session: external/user_turn frames, no local echo (ADR 0012)', () {
    final c = controller();
    c.applyFrame({'t': 'history', 'messages': []});
    c.applyFrame({'t': 'external', 'status': 'busy', 'canReply': true});
    expect(c.external?.canReply, true);
    expect(c.busy, true, reason: 'busy follows the CLI');

    c.sendUser('also check the tests');
    expect(c.messages, isEmpty, reason: 'the turn arrives back via the transcript');
    c.applyFrame({'t': 'user_turn', 'text': 'also check the tests'});
    expect(c.messages.single.role, ChatRole.user);

    c.applyFrame({'t': 'external', 'status': 'idle', 'canReply': true});
    expect(c.busy, false);

    // CLI exited → reconnect lands on the SDK path: history without `external`.
    c.applyFrame({'t': 'history', 'messages': []});
    expect(c.external, isNull);
    c.sendUser('hi');
    expect(c.messages.single.text, 'hi', reason: 'normal sessions echo locally again');
  });

  test('search hit → bubble: exact ts from history, else newest same-role text', () {
    final c = controller();
    c.applyFrame({
      't': 'history',
      'messages': [
        {'role': 'user', 'content': 'run tests', 'ts': '2026-10-06T10:00:00Z'},
        {'role': 'assistant', 'content': 'done', 'ts': '2026-10-06T10:00:05Z'},
        {'role': 'user', 'content': 'run tests', 'ts': '2026-10-06T11:00:00Z'},
      ],
    });
    c.applyFrame({'t': 'assistant', 'text': 'live reply'}); // no ts until a reattach
    final m = c.messages;
    expect(findHitIndex(m, role: 'user', content: 'run tests', ts: '2026-10-06T10:00:00Z'), 0, reason: 'ts disambiguates repeats');
    expect(findHitIndex(m, role: 'user', content: 'run tests', ts: '2026-10-06T11:00:00Z'), 2);
    expect(findHitIndex(m, role: 'assistant', content: 'live reply', ts: '2026-10-06T12:00:00Z'), 3);
    expect(findHitIndex(m, role: 'assistant', content: 'never said', ts: 'x'), -1);
  });

  test('sendWhenLive queues until connected (a prompt into an already-open session)', () {
    final c = controller(); // never started → not live
    c.sendWhenLive('from prompt library');
    expect(c.messages, isEmpty, reason: 'queued, not sent while connecting');
  });
}
