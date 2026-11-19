import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/chat_message.dart';

/// Local cache of a Claude session's transcript, so the chat opens instantly
/// (showing the last-known messages) even when the daemon is unreachable.
///
/// One JSON file per session under the app's private support dir (proposal 71 S2):
/// not in SharedPreferences (loaded whole at start, readable in backups), and the
/// manifest disables Android backup. Removed when the session is ended from the app.
///
/// BOUNDED on purpose: one huge transcript (a 35 MB session was cached whole) once made
/// the app slow to open and then crash it on launch. Only the newest [maxMessages] are
/// kept and each file is held under [maxBytes]; an oversized file found on load is
/// deleted instead of parsed. All files together stay under [maxTotalBytes]: the least
/// recently written go first. Best-effort throughout: a storage error means no cache.
class TranscriptCache {
  const TranscriptCache({this.dir = getApplicationSupportDirectory});

  /// Where the `transcripts/` folder lives (tests pass a temp dir).
  final Future<Directory> Function() dir;

  static const maxMessages = 200;
  static const maxBytes = 1000000;
  static const maxTotalBytes = 20 * 1000000;

  static String _legacyKey(String sessionId) => 'transcript_$sessionId';

  Future<File?> _file(String sessionId) async {
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'); // never a path
    if (safe.isEmpty) return null;
    return File('${(await dir()).path}/transcripts/$safe.json');
  }

  Future<List<ChatMessage>> load(String sessionId) async {
    try {
      final f = await _file(sessionId);
      if (f == null) return [];
      String? raw;
      if (await f.exists()) {
        if (await f.length() > maxBytes * 2) {
          await f.delete();
          return [];
        }
        raw = await f.readAsString();
      } else {
        raw = await _migrate(sessionId, f);
      }
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      return list.map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  // An older build kept transcripts in SharedPreferences: move this one to its file.
  Future<String?> _migrate(String sessionId, File f) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_legacyKey(sessionId));
    if (raw == null) return null;
    await prefs.remove(_legacyKey(sessionId));
    if (raw.length > maxBytes * 2) return null;
    await _write(f, raw);
    return raw;
  }

  Future<void> save(String sessionId, List<ChatMessage> messages) async {
    try {
      final f = await _file(sessionId);
      if (f == null) return;
      var keep = messages.length > maxMessages ? messages.sublist(messages.length - maxMessages) : messages;
      var raw = jsonEncode(keep.map((m) => m.toJson()).toList());
      while (raw.length > maxBytes && keep.length > 1) {
        keep = keep.sublist(keep.length ~/ 2); // drop the older half until it fits
        raw = jsonEncode(keep.map((m) => m.toJson()).toList());
      }
      await _write(f, raw);
      await _prune(f.parent, keepNewest: f.path);
    } catch (_) {/* best-effort */}
  }

  /// The session was ended: its cached transcript goes with it.
  Future<void> delete(String sessionId) async {
    try {
      final f = await _file(sessionId);
      if (f != null && await f.exists()) await f.delete();
      (await SharedPreferences.getInstance()).remove(_legacyKey(sessionId));
    } catch (_) {/* best-effort */}
  }

  Future<void> _write(File f, String raw) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(raw, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _prune(Directory d, {required String keepNewest}) async {
    final files = [
      for (final e in d.listSync())
        if (e is File && e.path.endsWith('.json')) (file: e, stat: e.statSync()),
    ]..sort((a, b) => a.stat.modified.compareTo(b.stat.modified)); // oldest first
    var total = files.fold<int>(0, (n, x) => n + x.stat.size);
    for (final x in files) {
      if (total <= maxTotalBytes) break;
      if (x.file.path == keepNewest) continue;
      total -= x.stat.size;
      await x.file.delete();
    }
  }
}
