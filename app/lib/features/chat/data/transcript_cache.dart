import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/chat_message.dart';

/// Local cache of a Claude session's transcript, so the chat opens instantly
/// (showing the last-known messages) even when the daemon is unreachable.
/// Backed by shared_preferences, keyed per session.
///
/// BOUNDED on purpose: shared_preferences loads every key into memory at app start, so one huge
/// transcript (a 35 MB session was cached whole) made the app slow to open and then crash it on
/// launch. Only the newest [maxMessages] are kept and the JSON is held under [maxBytes]; an
/// oversized entry found on load is deleted instead of parsed.
class TranscriptCache {
  const TranscriptCache();

  static const maxMessages = 200;
  static const maxBytes = 1000000;

  static String _key(String sessionId) => 'transcript_$sessionId';

  Future<List<ChatMessage>> load(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(sessionId));
    if (raw == null) return [];
    if (raw.length > maxBytes * 2) {
      await prefs.remove(_key(sessionId));
      return [];
    }
    final list = jsonDecode(raw) as List;
    return list.map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<void> save(String sessionId, List<ChatMessage> messages) async {
    final prefs = await SharedPreferences.getInstance();
    var keep = messages.length > maxMessages ? messages.sublist(messages.length - maxMessages) : messages;
    var raw = jsonEncode(keep.map((m) => m.toJson()).toList());
    while (raw.length > maxBytes && keep.length > 1) {
      keep = keep.sublist(keep.length ~/ 2); // drop the older half until it fits
      raw = jsonEncode(keep.map((m) => m.toJson()).toList());
    }
    await prefs.setString(_key(sessionId), raw);
  }
}
