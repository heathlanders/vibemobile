import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the last model the user picked for a new Claude session (ADR 0007),
/// so the picker pre-selects it next time. Mirrors the SharedPreferences pattern
/// in core/chat_settings.dart. Stores just the model id string; null = never set.
class ModelPrefs {
  static const _key = 'last_model_id';

  static Future<String?> last() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> setLast(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
  }
}
