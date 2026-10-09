import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/turn_status.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';

ChatSessionController controller() =>
    ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

void main() {
  final t0 = DateTime(2026, 10, 6, 12);

  test('fmtDuration', () {
    expect(fmtDuration(const Duration(seconds: 7)), '7s');
    expect(fmtDuration(const Duration(seconds: 63)), '1m 03s');
    expect(fmtDuration(const Duration(minutes: 62)), '1h 02m');
  });

  test('label: phase + elapsed anchored to receipt', () {
    final s = TurnStatus.fromFrame({'phase': 'tool', 'tool': 'Bash', 'elapsedMs': 40000, 'idleMs': 0}, t0);
    expect(s.label(t0.add(const Duration(seconds: 7))), 'Running Bash… 47s');
    expect(TurnStatus.fromFrame({'phase': 'waiting'}, t0).label(t0), 'Waiting for approval… 0s');
  });

  test('stall: model quiet > 60s while thinking, but not during a tool run or approval wait', () {
    final quiet = {'elapsedMs': 90000, 'idleMs': 58000};
    final thinking = TurnStatus.fromFrame({...quiet, 'phase': 'thinking'}, t0);
    expect(thinking.stalledFor(t0), isNull);
    expect(thinking.label(t0.add(const Duration(seconds: 5))), 'Thinking… 1m 35s · no activity 1m 03s');
    expect(TurnStatus.fromFrame({...quiet, 'phase': 'tool', 'tool': 'Bash'}, t0).stalledFor(t0.add(const Duration(seconds: 5))), isNull);
  });

  test('stall: no heartbeat for > 15s flags any phase', () {
    final s = TurnStatus.fromFrame({'phase': 'tool', 'tool': 'Bash'}, t0);
    expect(s.stalledFor(t0.add(const Duration(seconds: 10))), isNull);
    expect(s.stalledFor(t0.add(const Duration(seconds: 16))), const Duration(seconds: 16));
  });

  test('status frames drive busy + turn; a reattach idle frame unsticks busy', () {
    final c = controller();
    c.sendUser('hi');
    expect(c.busy, true);
    expect(c.turn, isNotNull, reason: 'optimistic local turn before the first frame');

    c.applyFrame({'t': 'status', 'running': true, 'phase': 'writing', 'elapsedMs': 3000, 'idleMs': 0});
    expect(c.turn!.phase, 'writing');

    // Backgrounded through the end of the turn: the result was missed, and the
    // reattach's status frame says idle.
    c.applyFrame({'t': 'history', 'messages': []});
    c.applyFrame({'t': 'status', 'running': false});
    expect(c.busy, false);
    expect(c.turn, isNull);

    // Cold attach mid-turn: busy comes back from the daemon.
    c.applyFrame({'t': 'status', 'running': true, 'phase': 'thinking', 'elapsedMs': 12000, 'idleMs': 1000});
    expect(c.busy, true);
    c.applyFrame({'t': 'result', 'subtype': 'success'});
    expect(c.turn, isNull);
  });
}
