import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/presentation/chat_controller_pool.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

/// Records lifecycle calls instead of opening a socket.
class _Fake extends ChatSessionController {
  _Fake() : super(url: Uri.parse('ws://x/session/s1'), token: 't');
  int starts = 0;
  bool disposed = false;
  @override
  void start() => starts++;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  test('two holders of one session share a single started controller', () {
    final pool = ChatControllerPool();
    var created = 0;
    _Fake make() {
      created++;
      return _Fake();
    }

    void tab() {}
    void grid() {}
    final a = pool.acquire('s1', make, onAuthFailed: tab) as _Fake;
    final b = pool.acquire('s1', make, onAuthFailed: grid);
    expect(identical(a, b), true);
    expect(created, 1);
    expect(a.starts, 1);

    pool.release('s1', tab);
    expect(a.disposed, false, reason: 'the grid still holds it');
    pool.release('s1', grid);
    expect(a.disposed, true, reason: 'last holder gone → socket closes');

    final c = pool.acquire('s1', make, onAuthFailed: tab);
    expect(identical(c, a), false, reason: 'a fresh controller after full release');
  });

  test('re-auth goes to a holder that is still alive', () {
    final pool = ChatControllerPool();
    final calls = <String>[];
    void tab() => calls.add('tab');
    void grid() => calls.add('grid');
    final c = pool.acquire('s1', _Fake.new, onAuthFailed: grid);
    pool.acquire('s1', _Fake.new, onAuthFailed: tab);
    pool.release('s1', tab); // tab closed: its handler must not fire
    c.onAuthFailed!();
    expect(calls, ['grid']);
  });

  test('different sessions get different controllers', () {
    final pool = ChatControllerPool();
    void h() {}
    expect(identical(pool.acquire('s1', _Fake.new, onAuthFailed: h), pool.acquire('s2', _Fake.new, onAuthFailed: h)), false);
  });
}
