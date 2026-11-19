import 'dart:io';

import 'package:dio/dio.dart';

/// One short, readable line for an error shown to the user (proposal 70 C10).
/// Never a raw exception dump: the daemon's own `{error}` text when it sent one,
/// otherwise what the user can do about it.
String friendlyError(Object e) {
  const unreachable = "Can't reach the server. Check that Tailscale is connected.";
  const slow = "The server didn't answer in time. Check that Tailscale is connected.";
  if (e is SocketException) return unreachable;
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout:
        return slow;
      case DioExceptionType.connectionError:
        return unreachable;
      case DioExceptionType.badResponse:
        final data = e.response?.data;
        if (data is Map && data['error'] is String && (data['error'] as String).isNotEmpty) return data['error'] as String;
        return 'The server hit an error (${e.response?.statusCode}). Try again.';
      default:
        return e.error is SocketException ? unreachable : 'Something went wrong. Try again.';
    }
  }
  // Our API classes throw Exception('<readable message>') or their own Exception types
  // whose toString() is the message. Parse errors and programming errors stay generic.
  if (e is Exception && e is! FormatException) return e.toString().replaceFirst(RegExp(r'^Exception: '), '');
  return 'Something went wrong. Try again.';
}
