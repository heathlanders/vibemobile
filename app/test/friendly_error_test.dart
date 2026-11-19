import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/errors.dart';

// Proposal 70 C10: users see a short, readable reason, never a raw exception dump.
void main() {
  final req = RequestOptions(path: '/projects');
  DioException dio(DioExceptionType type, {int? status, Object? data}) => DioException(
        requestOptions: req,
        type: type,
        response: status == null ? null : Response(requestOptions: req, statusCode: status, data: data),
      );

  test('maps the common failures to one short line', () {
    expect(friendlyError(dio(DioExceptionType.connectionTimeout)), "The server didn't answer in time. Check that Tailscale is connected.");
    expect(friendlyError(dio(DioExceptionType.receiveTimeout)), "The server didn't answer in time. Check that Tailscale is connected.");
    expect(friendlyError(dio(DioExceptionType.connectionError)), "Can't reach the server. Check that Tailscale is connected.");
    expect(friendlyError(const SocketException('Failed host lookup')), "Can't reach the server. Check that Tailscale is connected.");
    expect(friendlyError(dio(DioExceptionType.badResponse, status: 409, data: {'error': 'the branch moved'})), 'the branch moved');
    expect(friendlyError(dio(DioExceptionType.badResponse, status: 502)), 'The server hit an error (502). Try again.');
    expect(friendlyError(Exception('could not clear sessions (500)')), 'could not clear sessions (500)');
    expect(friendlyError(_ApiError('value must be between 50 and 99')), 'value must be between 50 and 99');
    expect(friendlyError(const FormatException('Unexpected character')), 'Something went wrong. Try again.');
    expect(friendlyError(StateError('x')), 'Something went wrong. Try again.');
  });

  test('never shows a DioException dump', () {
    expect(friendlyError(dio(DioExceptionType.unknown)), isNot(contains('DioException')));
  });
}

class _ApiError implements Exception {
  const _ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}
