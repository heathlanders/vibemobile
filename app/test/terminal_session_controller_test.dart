import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/reconnect.dart';

void main() {
  group('actionForCloseCode (reattach.md close-code policy)', () {
    test('1000 and 4404 stop (no resurrect)', () {
      expect(actionForCloseCode(1000), CloseAction.stop);
      expect(actionForCloseCode(4404), CloseAction.stop);
      expect(actionForCloseCode(4429), CloseAction.stop, reason: 'live cap — retry cannot help');
    });

    test('4401 re-auths', () {
      expect(actionForCloseCode(4401), CloseAction.reauth);
    });

    test('transient / unknown / null retry', () {
      expect(actionForCloseCode(1006), CloseAction.retry);
      expect(actionForCloseCode(1012), CloseAction.retry);
      expect(actionForCloseCode(null), CloseAction.retry);
    });
  });

  group('backoffDelay', () {
    // rng=0.5 → jitter exactly 1.0 → bare schedule: 0.5,1,2,4,8s, cap 10s.
    double mid() => 0.5;

    test('doubles per attempt then caps at 10s', () {
      expect(backoffDelay(0, rng: mid).inMilliseconds, 500);
      expect(backoffDelay(1, rng: mid).inMilliseconds, 1000);
      expect(backoffDelay(2, rng: mid).inMilliseconds, 2000);
      expect(backoffDelay(3, rng: mid).inMilliseconds, 4000);
      expect(backoffDelay(4, rng: mid).inMilliseconds, 8000);
      expect(backoffDelay(5, rng: mid).inMilliseconds, 10000); // 16 → capped
      expect(backoffDelay(9, rng: mid).inMilliseconds, 10000);
    });

    test('applies ±20% jitter at the bounds', () {
      expect(backoffDelay(1, rng: () => 0.0).inMilliseconds, 800); // 1000 * 0.8
      expect(backoffDelay(1, rng: () => 1.0).inMilliseconds, 1200); // 1000 * 1.2
    });
  });
}
