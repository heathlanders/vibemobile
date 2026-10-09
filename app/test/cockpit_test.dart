import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';
import 'package:vibemobile/features/settings/data/admin_api.dart';

void main() {
  test('Project keeps last_active (was dropped before phase 4a)', () {
    final p = Project.fromJson({
      'id': 'p1',
      'path': '/home/user/x',
      'name': 'x',
      'last_active': '2026-08-01T10:00:00.000Z',
    });
    expect(p.lastActive, DateTime.utc(2026, 8, 1, 10));
  });

  test('Project tolerates a missing/!parseable last_active', () {
    expect(Project.fromJson({'id': 'p', 'path': '/x'}).lastActive, isNull);
    expect(Project.fromJson({'id': 'p', 'path': '/x', 'last_active': 'nope'}).lastActive, isNull);
  });

  test('relativeAge renders compact ages', () {
    final now = DateTime.now();
    expect(relativeAge(null), '');
    expect(relativeAge(now), 'now');
    expect(relativeAge(now.subtract(const Duration(minutes: 20))), '20m');
    expect(relativeAge(now.subtract(const Duration(hours: 5))), '5h');
    expect(relativeAge(now.subtract(const Duration(days: 3))), '3d');
  });

  test('Session carries total_cost_usd and formats it', () {
    Session s(num cost) => Session.fromJson({
          'id': 's1',
          'project_id': 'p1',
          'kind': 'claude',
          'status': 'live',
          'created_at': '2026-08-01T10:00:00Z',
          'total_cost_usd': cost,
        });
    expect(s(0).costLabel, '', reason: 'Max sessions have no dollar figure to show');
    expect(s(0.0421).costLabel, '\$0.042');
    expect(s(1.2).costLabel, '\$1.20');
  });

  test('Session.canOpen: live rows and resumable claude rows only', () {
    Session s(String kind, String status, [String? csid]) => Session.fromJson({
          'id': 's1',
          'project_id': 'p1',
          'kind': kind,
          'status': status,
          'created_at': '2026-08-01T10:00:00Z',
          'claude_session_id': csid,
        });
    expect(s('claude', 'live').canOpen, true);
    expect(s('claude', 'stale', 'abc').canOpen, true, reason: 'discovered CLI session resumes on attach');
    expect(s('claude', 'stale').canOpen, false, reason: 'nothing to resume');
    expect(s('terminal', 'stale').canOpen, false, reason: 'tmux gone — nothing to reattach');
  });

  test('PairedDevice reads the current flag', () {
    final d = PairedDevice.fromJson({'id': 'd1', 'name': 'pixel', 'current': true});
    expect(d.current, true);
    expect(PairedDevice.fromJson({'id': 'd2', 'name': 'old'}).current, false);
  });

  test('AuditEvent parses a log row', () {
    final e = AuditEvent.fromJson({
      'id': 'e1',
      'kind': 'permission.deny',
      'device_id': 'd1',
      'detail': 's1:Bash',
      'ts': '2026-08-01T10:00:00Z',
    });
    expect(e.kind, 'permission.deny');
    expect(e.detail, 's1:Bash');
  });
}
