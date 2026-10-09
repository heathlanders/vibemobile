import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/core/theme.dart';
import 'package:vibemobile/features/chat/data/transcript_cache.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';
import 'package:vibemobile/features/sessions/domain/session.dart';

Session _s({String kind = 'claude', String status = 'live', String? title}) =>
    Session(id: 's1', projectId: 'p1', kind: kind, status: status, createdAt: 'now', title: title);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sessionMatches', () {
    test('empty query matches everything', () => expect(sessionMatches(_s(), 'proj', '  '), true));
    test('matches on project name', () => expect(sessionMatches(_s(), 'EcommerceSaaS', 'ecom'), true));
    test('matches title / kind / status', () {
      expect(sessionMatches(_s(title: 'build logs'), 'p', 'BUILD'), true);
      expect(sessionMatches(_s(kind: 'terminal'), 'p', 'term'), true);
      expect(sessionMatches(_s(status: 'stale'), 'p', 'stale'), true);
    });
    test('miss returns false', () => expect(sessionMatches(_s(title: 'x'), 'proj', 'zzz'), false));
  });

  group('AppTheme', () {
    test('dark is dark, light is light', () {
      expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);
      expect(AppTheme.light.colorScheme.brightness, Brightness.light);
    });
  });

  group('ChatMessage json', () {
    test('round-trips role / text / tool', () {
      final m = ChatMessage(role: ChatRole.tool, toolName: 'Read', toolInput: {'file': 'a'});
      final back = ChatMessage.fromJson(m.toJson());
      expect(back.role, ChatRole.tool);
      expect(back.toolName, 'Read');
      expect(back.toolInput!['file'], 'a');
    });
  });

  group('TranscriptCache', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('save then load returns the messages', () async {
      const cache = TranscriptCache();
      await cache.save('s1', [
        ChatMessage(role: ChatRole.user, text: 'hi'),
        ChatMessage(role: ChatRole.assistant, text: 'yo'),
      ]);
      final loaded = await cache.load('s1');
      expect(loaded.length, 2);
      expect(loaded.first.role, ChatRole.user);
      expect(loaded.last.text, 'yo');
    });

    test('unknown session loads empty', () async {
      expect(await const TranscriptCache().load('nope'), isEmpty);
    });
  });
}
