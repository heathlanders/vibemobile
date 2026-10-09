import 'package:flutter/foundation.dart';

/// A one-shot "Ctrl" for the soft keyboard, which has no Ctrl key. Arm it from the key
/// row, then type one letter: that character is sent as its control code instead
/// (Ctrl+C = 0x03, Ctrl+D = 0x04, Ctrl+L = 0x0C, …). Any input disarms it.
class CtrlLatch extends ChangeNotifier {
  bool _armed = false;
  bool get armed => _armed;

  void toggle() {
    _armed = !_armed;
    notifyListeners();
  }

  void clear() {
    if (!_armed) return;
    _armed = false;
    notifyListeners();
  }

  /// Applies a pending Ctrl to terminal input [data] and disarms. Only a single typed
  /// character maps to a control code; anything else (a paste, an escape sequence,
  /// a digit) passes through unchanged. Pure apart from the disarm.
  String take(String data) {
    if (!_armed) return data;
    _armed = false;
    notifyListeners();
    if (data.length != 1) return data;
    final c = data.codeUnitAt(0);
    final int? code;
    if (c >= 0x61 && c <= 0x7a) {
      code = c - 0x60; // a-z → 1..26
    } else if (c >= 0x41 && c <= 0x5a) {
      code = c - 0x40; // A-Z → 1..26
    } else if (c == 0x20) {
      code = 0; // Ctrl+Space → NUL
    } else if ('@[\\]^_'.contains(data)) {
      code = c & 0x1f; // @ [ \ ] ^ _ → 0, 27..31
    } else {
      code = null;
    }
    return code == null ? data : String.fromCharCode(code);
  }
}
