import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/notes/domain/note.dart';

void main() {
  final now = DateTime(2026, 10, 11, 15, 30);

  test('fmtMessageTime: time today, date on other days, year in other years', () {
    expect(fmtMessageTime(DateTime(2026, 10, 11, 9, 5, 7), now), '09:05:07');
    expect(fmtMessageTime(DateTime(2026, 10, 9, 14, 3, 22), now), 'Oct 9 14:03:22');
    expect(fmtMessageTime(DateTime(2025, 12, 31, 23, 59, 59), now), 'Dec 31 2025 23:59:59');
  });

  test('ChatMessage.at: server ts (local time) for history rows, now for live ones', () {
    final m = ChatMessage(role: ChatRole.user, ts: '2026-10-09T14:03:22.000Z');
    expect(m.at, DateTime.utc(2026, 10, 9, 14, 3, 22).toLocal());
    expect(m.at.isUtc, isFalse);
    final before = DateTime.now();
    final live = ChatMessage(role: ChatRole.assistant);
    expect(live.at.isBefore(before), isFalse);
    expect(ChatMessage(role: ChatRole.user, ts: 'garbage').at.isBefore(before), isFalse);
  });

  test('buildNotesPrompt: open notes as a list under the inbox workflow', () {
    final p = buildNotesPrompt([
      Note(id: 'a', projectId: 'p', text: 'add timestamps'),
      Note(id: 'b', projectId: 'p', text: 'two\nlines'),
    ]);
    expect(p, contains('resolve_note'));
    expect(p, endsWith('- add timestamps\n- two\n  lines'));
  });
}
