import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/features/chat/data/transcript_cache.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';

void main() {
  const cache = TranscriptCache();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips a small transcript', () async {
    await cache.save('s', [ChatMessage(role: ChatRole.user, text: 'hi'), ChatMessage(role: ChatRole.assistant, text: 'yo')]);
    final back = await cache.load('s');
    expect(back.map((m) => m.text), ['hi', 'yo']);
  });

  test('keeps only the newest messages', () async {
    await cache.save('s', [for (var i = 0; i < 1000; i++) ChatMessage(role: ChatRole.assistant, text: 'm$i')]);
    final back = await cache.load('s');
    expect(back.length, TranscriptCache.maxMessages);
    expect(back.last.text, 'm999');
  });

  test('huge messages are trimmed to the byte budget', () async {
    final big = 'x' * 300000;
    await cache.save('s', [for (var i = 0; i < 20; i++) ChatMessage(role: ChatRole.assistant, text: '$i$big')]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('transcript_s')!.length, lessThanOrEqualTo(TranscriptCache.maxBytes + 400000));
    final back = await cache.load('s');
    expect(back, isNotEmpty);
    expect(back.last.text.startsWith('19'), isTrue);
  });

  test('an oversized stored entry is deleted on load, not parsed', () async {
    SharedPreferences.setMockInitialValues({'transcript_s': 'x' * (TranscriptCache.maxBytes * 2 + 1)});
    expect(await cache.load('s'), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('transcript_s'), isFalse);
  });
}
