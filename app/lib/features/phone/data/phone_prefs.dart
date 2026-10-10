import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the phone shell's last selected project and last opened session
/// across launches (proposal 54). Stale ids are ignored by the shell on load.
class PhonePrefs {
  static const _projectKey = 'phone_last_project_id';
  static const _sessionKey = 'phone_last_session_id';

  static Future<(String?, String?)> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_projectKey), prefs.getString(_sessionKey));
  }

  static Future<void> saveProject(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_projectKey, id);
  }

  static Future<void> saveSession(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_sessionKey);
    } else {
      await prefs.setString(_sessionKey, id);
    }
  }
}
