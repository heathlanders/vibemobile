import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/chat_settings.dart';
import 'package:vibemobile/features/chat/domain/session_mode.dart';
import 'package:vibemobile/features/chat/presentation/chat_session_controller.dart';
import 'package:vibemobile/features/notifications/domain/push_note.dart';

ChatSessionController controller() =>
    ChatSessionController(url: Uri.parse('ws://x/session/s1'), token: 't');

Map<String, dynamic> planDialog() => {
      't': 'user_dialog',
      'dialogId': 'd1',
      'dialogKind': 'exit_plan',
      'payload': {'plan': '# Add caching\n- step one'},
    };

void main() {
  test('SessionMode.fromWire knows exactly ask/auto/plan', () {
    expect(SessionMode.fromWire('plan'), SessionMode.plan);
    expect(SessionMode.fromWire('ask'), SessionMode.ask);
    expect(SessionMode.fromWire('auto'), SessionMode.auto);
    expect(SessionMode.fromWire('bypassPermissions'), isNull);
    expect(SessionMode.fromWire(null), isNull);
  });

  test('mode frame sets the mode and the available list; unknown names are dropped', () {
    final c = controller();
    expect(c.mode, isNull, reason: 'chip hidden until the daemon reports');
    c.applyFrame({'t': 'mode', 'mode': 'plan', 'available': ['ask', 'auto', 'plan', 'someFutureMode']});
    expect(c.mode, SessionMode.plan);
    expect(c.availableModes, [SessionMode.ask, SessionMode.auto, SessionMode.plan]);

    c.applyFrame({'t': 'mode', 'mode': 'ask', 'available': ['ask', 'auto']});
    expect(c.mode, SessionMode.ask);
    expect(c.availableModes, [SessionMode.ask, SessionMode.auto], reason: 'native session: no Plan');
  });

  test('exit_plan dialog is shown, not auto-cancelled; answering clears it', () {
    final c = controller();
    c.applyFrame(planDialog());
    expect(c.pendingDialog, isNotNull);
    expect(c.pendingDialog!.isExitPlan, true);
    expect(c.pendingDialog!.plan, startsWith('# Add caching'));

    c.respondExitPlan(approve: true, approveMode: SessionMode.auto);
    expect(c.pendingDialog, isNull);
  });

  test('respondExitPlan ignores a non-plan dialog', () {
    final c = controller();
    c.applyFrame({
      't': 'user_dialog',
      'dialogId': 'q1',
      'dialogKind': 'ask_user_question',
      'payload': {
        'questions': [
          {'question': 'DB?', 'options': []},
        ],
      },
    });
    c.respondExitPlan(approve: true);
    expect(c.pendingDialog, isNotNull, reason: 'only a plan dialog can be answered as a plan');
  });

  test('a notification for a ready plan has no one-tap buttons', () {
    final n = buildNotes('question', 's1', {
      'dialogs': [planDialog()],
    }).single;
    expect(n.title, contains('plan ready'));
    expect(n.body, 'Add caching');
    expect(n.actions, isEmpty, reason: 'a plan has to be read, not tapped through');
  });

  test('default mode: stored value wins, legacy auto-allow bool is the fallback', () async {
    SharedPreferences.setMockInitialValues({'default_session_mode': 'plan'});
    expect(await loadDefaultMode(), SessionMode.plan);

    SharedPreferences.setMockInitialValues({'auto_allow_permissions': false});
    expect(await loadDefaultMode(), SessionMode.ask);

    SharedPreferences.setMockInitialValues({'auto_allow_permissions': true});
    expect(await loadDefaultMode(), SessionMode.auto);

    SharedPreferences.setMockInitialValues({});
    expect(await loadDefaultMode(), SessionMode.auto);
  });

  test('nextMode cycles ask → auto → plan → ask over the available modes', () {
    const all = [SessionMode.ask, SessionMode.auto, SessionMode.plan];
    expect(nextMode(SessionMode.ask, all), SessionMode.auto);
    expect(nextMode(SessionMode.auto, all), SessionMode.plan);
    expect(nextMode(SessionMode.plan, all), SessionMode.ask);
    // Native engine has no plan: ask ↔ auto.
    expect(nextMode(SessionMode.auto, const [SessionMode.ask, SessionMode.auto]), SessionMode.ask);
    expect(nextMode(SessionMode.ask, const [SessionMode.ask]), isNull);
    expect(nextMode(SessionMode.ask, const []), isNull);
  });
}
