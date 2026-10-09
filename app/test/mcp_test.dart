import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/mcp_server.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/chat/presentation/mcp_sheet.dart';

ChatSessionController controller() => ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

Map<String, dynamic> server(String name, String status, {int tools = 0, String? error, String? version, String? scope, List<Map<String, dynamic>>? list}) => {
      'name': name,
      'status': status,
      'toolCount': tools,
      'tools': list ?? [for (var i = 0; i < tools; i++) {'name': 't$i', 'description': 'tool $i'}],
      'error': ?error,
      'version': ?version,
      'scope': ?scope,
    };

void main() {
  group('McpServerInfo', () {
    test('parses a frame entry; summary reads like a status line', () {
      final s = McpServerInfo.tryFromJson(server('github', 'connected', tools: 12, version: '1.4.2', scope: 'user'))!;
      expect([s.name, s.status, s.version, s.scope, s.toolCount], ['github', 'connected', '1.4.2', 'user', 12]);
      expect(s.summary, 'Connected · 12 tools · v1.4.2');
      expect(McpServerInfo.tryFromJson(server('x', 'connected', tools: 1))!.summary, 'Connected · 1 tool');
      expect(McpServerInfo.tryFromJson(server('x', 'failed'))!.summary, 'Failed to start');
      expect(McpServerInfo.tryFromJson(server('x', 'needs-auth'))!.statusLabel, 'Needs authorization');
    });

    test('only reconnectable states offer Reconnect; disabled offers turn-on', () {
      McpServerInfo s(String st) => McpServerInfo.tryFromJson(server('x', st))!;
      expect([for (final st in ['connected', 'failed', 'needs-auth', 'pending', 'disabled', 'unknown']) s(st).canReconnect], [false, true, false, true, false, true]);
      expect(s('disabled').disabled, true);
      expect(s('needs-auth').needsAuth, true);
    });

    test('tool annotations; the real count survives a capped list', () {
      final s = McpServerInfo.tryFromJson(server('x', 'connected', tools: 500, list: [
        {'name': 'a', 'readOnly': true},
        {'name': 'b', 'destructive': true, 'description': 'dangerous'},
      ]))!;
      expect(s.toolCount, 500);
      expect(s.tools.length, 2);
      expect([s.tools[0].readOnly, s.tools[1].destructive, s.tools[1].description], [true, true, 'dangerous']);
    });

    test('junk never throws: bad entries are null, bad fields default', () {
      for (final bad in [null, 5, 'x', [], <String, dynamic>{}, {'name': 3}, {'name': ''}]) {
        expect(McpServerInfo.tryFromJson(bad), isNull, reason: '$bad');
      }
      final s = McpServerInfo.tryFromJson({'name': 'ok', 'status': 7, 'tools': [null, 3, {'name': 5}, {'name': 'fine'}], 'version': [], 'error': ''})!;
      expect([s.status, s.version, s.error, s.tools.length], ['unknown', null, null, 1]);
    });
  });

  group('controller', () {
    test('null until the daemon answers; an mcp frame fills the list and the truncation flag', () {
      final c = controller();
      expect(c.mcpServers, isNull);
      c.applyFrame({'t': 'mcp', 'servers': [server('a', 'connected'), 5, server('b', 'failed')], 'truncated': true});
      expect(c.mcpServers!.map((s) => s.name), ['a', 'b']);
      expect(c.mcpTruncated, true);
      c.applyFrame({'t': 'mcp', 'servers': 'oops'});
      expect(c.mcpServers, isEmpty, reason: 'a malformed list becomes "none", not a crash');
    });

    test('isClaudeEngine follows the frames only the Claude engine sends', () {
      final c = controller();
      expect(c.isClaudeEngine, false);
      c.applyFrame({'t': 'effort', 'effort': null, 'levels': ['low', 'high']});
      expect(c.isClaudeEngine, true);
      expect(controller()..applyFrame({'t': 'model', 'model': 'm', 'canSwitch': true}), isA<ChatSessionController>());
    });

    test('requestMcp / mcpAction with no socket are harmless no-ops', () {
      expect(() => controller()
        ..requestMcp()
        ..mcpAction('a', 'disable'), returnsNormally);
    });
  });

  group('McpSheet', () {
    Future<ChatSessionController> pump(WidgetTester t, {List<Map<String, dynamic>>? servers, bool truncated = false}) async {
      final c = controller();
      if (servers != null) c.applyFrame({'t': 'mcp', 'servers': servers, 'truncated': truncated});
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 700, child: McpSheet(controller: c)))));
      await t.pump();
      return c;
    }

    testWidgets('a spinner until the first answer', (t) async {
      await pump(t);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('says plainly when there are no servers', (t) async {
      await pump(t, servers: []);
      expect(find.text('No MCP servers are configured for this session.'), findsOneWidget);
    });

    testWidgets('lists each server with its state; expanding shows tools, errors and the auth note', (t) async {
      await pump(t, servers: [
        server('github', 'connected', tools: 2, version: '1.0', list: [
          {'name': 'search_code', 'description': 'Search code', 'readOnly': true},
          {'name': 'delete_repo', 'destructive': true},
        ]),
        server('broken', 'failed', error: 'ENOENT: no such file'),
        server('claude.ai Gmail', 'needs-auth'),
      ]);
      expect(find.text('github'), findsOneWidget);
      expect(find.text('Connected · 2 tools · v1.0'), findsOneWidget);
      expect(find.text('Failed to start'), findsOneWidget);
      expect(find.text('Needs authorization'), findsOneWidget);
      await t.tap(find.text('github'));
      await t.pumpAndSettle();
      expect(find.textContaining('search_code'), findsOneWidget);
      expect(find.textContaining('read-only'), findsOneWidget);
      expect(find.textContaining('can change things'), findsOneWidget);
      await t.tap(find.text('broken'));
      await t.pumpAndSettle();
      expect(find.text('ENOENT: no such file'), findsOneWidget);
      await t.tap(find.text('claude.ai Gmail'));
      await t.pumpAndSettle();
      expect(find.textContaining('needs to be authorized'), findsOneWidget);
    });

    testWidgets('the actions menu offers Reconnect only where it applies, and Turn on for a disabled server', (t) async {
      await pump(t, servers: [server('up', 'connected'), server('down', 'failed'), server('off', 'disabled')]);
      Future<List<String>> menuFor(int i) async {
        await t.tap(find.byTooltip('Actions').at(i));
        await t.pumpAndSettle();
        final items = <String>[
          for (final s in ['Reconnect', 'Turn off for this chat', 'Turn on']) if (find.text(s).evaluate().isNotEmpty) s,
        ];
        await t.tapAt(const Offset(5, 5)); // dismiss
        await t.pumpAndSettle();
        return items;
      }

      expect(await menuFor(0), ['Turn off for this chat']);
      expect(await menuFor(1), ['Reconnect', 'Turn off for this chat']);
      expect(await menuFor(2), ['Turn on']);
    });

    testWidgets('a capped list says so', (t) async {
      await pump(t, servers: [server('a', 'connected')], truncated: true);
      expect(find.textContaining('list is capped'), findsOneWidget);
    });
  });
}
