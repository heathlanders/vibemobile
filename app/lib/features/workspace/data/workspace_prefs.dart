import 'package:shared_preferences/shared_preferences.dart';

/// Remembers the desktop workspace's open tabs (ADR 0015) so a relaunch
/// restores them. Same SharedPreferences pattern as MultiChatPrefs; dead or
/// deleted ids are pruned on load by the workspace screen.
class WorkspacePrefs {
  static const _idsKey = 'workspace_tab_ids';
  static const _activeKey = 'workspace_active_id';

  static Future<(List<String>, String?)> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_idsKey) ?? const <String>[], prefs.getString(_activeKey));
  }

  static Future<void> save(List<String> ids, String? active) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_idsKey, ids);
    if (active == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, active);
    }
  }
}
