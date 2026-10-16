import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows focus plumbing for the editor window (proposal 62), via user32. Every call is a
/// no-op elsewhere and swallows failures: losing focus handover must never break opening a file.
abstract final class EditorNative {
  static const windowTitle = 'VibeMobile Editor';
  static const _asfwAny = 0xFFFFFFFF; // ASFW_ANY
  static const _swRestore = 9;

  static DynamicLibrary? _lib;
  static DynamicLibrary get _user32 => _lib ??= DynamicLibrary.open('user32.dll');

  /// Main window, before it starts or messages the editor: let any process take the foreground.
  static void allowAnyForeground() {
    if (!Platform.isWindows) return;
    try {
      _user32.lookupFunction<Int32 Function(Uint32), int Function(int)>('AllowSetForegroundWindow')(_asfwAny);
    } catch (_) {}
  }

  /// Editor window: restore if minimized and take the foreground.
  static void bringToFront() {
    if (!Platform.isWindows) return;
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final title = windowTitle.toNativeUtf16();
    try {
      final find = _user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
      final hwnd = find(cls, title);
      if (hwnd == 0) return;
      final isIconic = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
      if (isIconic(hwnd) != 0) {
        _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow')(hwnd, _swRestore);
      }
      _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow')(hwnd);
    } catch (_) {
    } finally {
      malloc.free(cls);
      malloc.free(title);
    }
  }
}
