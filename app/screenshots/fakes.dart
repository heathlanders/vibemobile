// ignore_for_file: invalid_use_of_visible_for_testing_member
// Fake data and fakes for the screenshots. Everything here is made up: the
// repo is public, so no real hosts, paths or names (proposal 50).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vibemobile/core/reconnect.dart';
import 'package:vibemobile/core/token_store.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

const creds = Creds('https://box.tailnet.ts.net', 'demo-token');

Session fakeSession(String id, String title, {String projectId = 'p1', String kind = 'claude', String status = 'live'}) =>
    Session(id: id, projectId: projectId, kind: kind, status: status, createdAt: '2026-10-01T09:00:00Z', title: title);

const _ts = '2026-10-10T09:30:00Z';

Map<String, dynamic> _row(String id, String role, String content) => {'id': id, 'role': role, 'content': content, 'ts': _ts};

Map<String, dynamic> _tool(String id, String name, Map<String, dynamic> input, String result) => {
      'role': 'tool',
      'tool_json': jsonEncode({'id': id, 'name': name, 'input': input, 'result': result}),
    };

const overviewReply = '''# Auth flow notes

I read the plan and the login code. The short version:

- Tokens are issued in `src/auth/login.ts:42` and checked on every request.
- Pairing is described in docs/PLAN.md under "Security".
- Refresh is not implemented yet.

```ts
export function verify(token: string): boolean {
  return store.has(hash(token));
}
```

Want me to add token refresh next?''';

/// A connected controller holding [rows] as if replayed from the daemon.
/// Never started, so no socket is opened.
ChatSessionController fakeController(String id, List<Map<String, dynamic>> rows) {
  final c = ChatSessionController(url: Uri.parse('wss://box.tailnet.ts.net/session/$id'), token: 'demo-token');
  c.state = ConnState.live;
  c.applyFrame({'t': 'history', 'messages': rows});
  return c;
}

List<Map<String, dynamic>> overviewRows() => [
      _row('m1', 'user', 'Walk me through how login works in this project.'),
      _tool('t1', 'Read', {'file_path': 'docs/PLAN.md'}, '# Plan\n...'),
      _tool('t2', 'Read', {'file_path': 'src/auth/login.ts'}, 'export function login() {}'),
      _tool('t3', 'Grep', {'pattern': 'verify'}, 'src/auth/login.ts:42'),
      _row('m2', 'assistant', overviewReply),
    ];

/// Hands out pre-built controllers instead of opening sockets.
class FakePool extends ChatControllerPool {
  FakePool(this.controllers);
  final Map<String, ChatSessionController> controllers;

  @override
  ChatSessionController acquire(
    String sessionId,
    ChatSessionController Function() create, {
    required void Function() onAuthFailed,
  }) =>
      controllers.putIfAbsent(sessionId, create);

  @override
  void release(String sessionId, void Function() onAuthFailed) {}
}

/// Canned REST answers keyed by path; anything else is a 404.
class FakeHttp extends HttpOverrides {
  FakeHttp(this.routes);
  final Map<String, Object> routes;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(routes);
}

class _Client implements HttpClient {
  _Client(this.routes);
  final Map<String, Object> routes;

  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _Request(routes[url.path]);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  final map = <String, List<String>>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => map[name] = ['$value'];
  @override
  void forEach(void Function(String name, List<String> values) action) => map.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.body);
  final Object? body;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async => _Response(body);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Object? body)
      : statusCode = body == null ? 404 : 200,
        _bytes = utf8.encode(jsonEncode(body ?? {'error': 'not found'}));
  final List<int> _bytes;
  @override
  final int statusCode;
  @override
  final HttpHeaders headers = _Headers()..map['content-type'] = ['application/json'];
  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Not Found';
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  int get contentLength => _bytes.length;
  @override
  bool get persistentConnection => false;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(_bytes).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
