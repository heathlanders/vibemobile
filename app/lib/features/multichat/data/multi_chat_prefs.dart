import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which sessions the multi-chat grid was showing (proposal 19), so
/// relaunching the app restores the same set. Mirrors the SharedPreferences
/// pattern in sessions/data/model_prefs.dart. Stores just the session ids, in
/// grid order; dead/deleted ids are pruned on load by the grid screen.
class MultiChatPrefs {
  static const _key = 'multi_chat_session_ids';

  static Future<List<String>> ids() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? const [];
  }

  static Future<void> setIds(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, ids);
  }
}
