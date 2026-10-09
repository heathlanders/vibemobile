import 'package:shared_preferences/shared_preferences.dart';

import '../domain/task_profile.dart';

/// The model the user assigned to each [TaskKind], on this device. Same
/// SharedPreferences pattern as model_prefs.dart. Null = no profile (default).
class TaskModelPrefs {
  static String _id(TaskKind k) => 'task_model_${k.name}';
  static String _label(TaskKind k) => 'task_model_label_${k.name}';

  static Future<({String id, String label})?> get(TaskKind k) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_id(k));
    return id == null ? null : (id: id, label: prefs.getString(_label(k)) ?? id);
  }

  static Future<void> set(TaskKind k, ({String id, String label})? model) async {
    final prefs = await SharedPreferences.getInstance();
    if (model == null) {
      await prefs.remove(_id(k));
      await prefs.remove(_label(k));
    } else {
      await prefs.setString(_id(k), model.id);
      await prefs.setString(_label(k), model.label);
    }
  }
}
