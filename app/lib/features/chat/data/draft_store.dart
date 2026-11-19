import 'package:shared_preferences/shared_preferences.dart';

/// Unsent composer text per session (proposal 70 C5), so leaving a chat, switching
/// tabs or the app being killed doesn't lose a half-written message. Empty text
/// removes the entry. Best-effort: a storage failure means no draft, never a broken chat.
class DraftStore {
  static String _key(String sessionId) => 'draft:$sessionId';

  static Future<String?> load(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(sessionId));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String sessionId, String text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (text.trim().isEmpty) {
        await prefs.remove(_key(sessionId));
      } else {
        await prefs.setString(_key(sessionId), text);
      }
    } catch (_) {/* best-effort */}
  }
}
