import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/notifications/data/push_service.dart';

void main() {
  testWidgets('a session is visible only while registered, on screen and the app is resumed', (tester) async {
    var onScreen = true;
    bool check() => onScreen;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(PushService.isVisible('s1'), isFalse, reason: 'nothing registered');
    PushService.registerVisible('s1', check);
    expect(PushService.isVisible('s1'), isTrue);

    onScreen = false; // another route pushed on top
    expect(PushService.isVisible('s1'), isFalse);

    onScreen = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(PushService.isVisible('s1'), isFalse, reason: 'backgrounded = not visible');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    PushService.unregisterVisible('s1', check);
    expect(PushService.isVisible('s1'), isFalse);
  });
}
