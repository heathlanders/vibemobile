import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibemobile/features/chat/data/transcript_cache.dart';
import 'package:vibemobile/features/chat/domain/chat_message.dart';

// Transcript cache (proposal 71 S2): files in the app's private dir, bounded per
// session and in total, deleted with the session, migrated off SharedPreferences.
void main() {
  late Directory dir;
  late TranscriptCache cache;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('vibe-transcripts-');
    cache = TranscriptCache(dir: () async => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File fileFor(String id) => File('${dir.path}/transcripts/$id.json');

  test('round-trips a small transcript, stored as a private file', () async {
    await cache.save('s', [ChatMessage(role: ChatRole.user, text: 'hi'), ChatMessage(role: ChatRole.assistant, text: 'yo')]);
    expect(fileFor('s').existsSync(), isTrue);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty, reason: 'nothing in SharedPreferences');
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
    expect(fileFor('s').lengthSync(), lessThanOrEqualTo(TranscriptCache.maxBytes + 400000));
    final back = await cache.load('s');
    expect(back, isNotEmpty);
    expect(back.last.text.startsWith('19'), isTrue);
  });

  test('an oversized stored file is deleted on load, not parsed', () async {
    fileFor('s').createSync(recursive: true);
    fileFor('s').writeAsStringSync('x' * (TranscriptCache.maxBytes * 2 + 1));
    expect(await cache.load('s'), isEmpty);
    expect(fileFor('s').existsSync(), isFalse);
  });

  test('delete removes a session transcript', () async {
    await cache.save('s', [ChatMessage(role: ChatRole.user, text: 'hi')]);
    await cache.delete('s');
    expect(fileFor('s').existsSync(), isFalse);
    expect(await cache.load('s'), isEmpty);
  });

  test('total size is capped: the oldest transcripts go first', () async {
    final big = 'y' * 900000;
    for (var i = 0; i < 30; i++) {
      await cache.save('s$i', [ChatMessage(role: ChatRole.assistant, text: big)]);
      fileFor('s$i').setLastModifiedSync(DateTime(2026, 1, 1).add(Duration(minutes: i)));
    }
    await cache.save('latest', [ChatMessage(role: ChatRole.assistant, text: 'z')]);
    final files = Directory('${dir.path}/transcripts').listSync().whereType<File>().toList();
    final total = files.fold<int>(0, (n, f) => n + f.lengthSync());
    expect(total, lessThanOrEqualTo(TranscriptCache.maxTotalBytes));
    expect(fileFor('s0').existsSync(), isFalse, reason: 'oldest dropped');
    expect(fileFor('latest').existsSync(), isTrue);
    expect(fileFor('s29').existsSync(), isTrue);
  });

  test('a transcript left in SharedPreferences by an older build moves to a file', () async {
    SharedPreferences.setMockInitialValues({'transcript_old': '[{"role":"user","text":"from before"}]'});
    final back = await cache.load('old');
    expect(back.single.text, 'from before');
    expect((await SharedPreferences.getInstance()).containsKey('transcript_old'), isFalse);
    expect(fileFor('old').existsSync(), isTrue);
  });

  test('a session id cannot escape the cache dir', () async {
    await cache.save('../../evil', [ChatMessage(role: ChatRole.user, text: 'x')]);
    expect(File('${dir.path}/../evil.json').existsSync(), isFalse);
  });
}
