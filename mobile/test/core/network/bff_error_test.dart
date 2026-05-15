import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/bff_error.dart';

DioException _err({
  int? status,
  Object? body,
  DioExceptionType type = DioExceptionType.badResponse,
}) {
  final req = RequestOptions(path: '/x');
  return DioException(
    requestOptions: req,
    type: type,
    response: status == null
        ? null
        : Response<dynamic>(
            requestOptions: req,
            statusCode: status,
            data: body,
          ),
  );
}

void main() {
  group('describeBffError', () {
    test('extracts error_description from BFF envelope', () {
      final info = _err(
        status: 422,
        body: {'error': 'otp_invalid', 'error_description': 'bad code'},
      );
      final parsed = describeBffError(info);
      expect(parsed.statusCode, 422);
      expect(parsed.errorDescription, 'bad code');
      expect(parsed.isTimeout, isFalse);
      expect(parsed.attemptsLeft, isNull);
    });

    test('extracts attempts_left from detail', () {
      final info = _err(
        status: 422,
        body: {
          'error': 'otp_invalid',
          'detail': {'attempts_left': 3},
        },
      );
      final parsed = describeBffError(info);
      expect(parsed.attemptsLeft, 3);
    });

    test('isTimeout true for connectionTimeout/receiveTimeout/sendTimeout', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(describeBffError(_err(type: t)).isTimeout, isTrue,
            reason: '$t should be timeout');
      }
    });

    test('isTimeout false for badResponse / unknown', () {
      expect(describeBffError(_err(status: 500)).isTimeout, isFalse);
      expect(
        describeBffError(_err(type: DioExceptionType.unknown)).isTimeout,
        isFalse,
      );
    });

    test('statusCode is null for transport-level errors', () {
      final parsed = describeBffError(
        _err(type: DioExceptionType.connectionTimeout),
      );
      expect(parsed.statusCode, isNull);
    });

    test('non-Map body is tolerated', () {
      final parsed = describeBffError(_err(status: 502, body: 'Bad Gateway'));
      expect(parsed.statusCode, 502);
      expect(parsed.errorDescription, isNull);
      expect(parsed.attemptsLeft, isNull);
    });

    test('null body is tolerated', () {
      final parsed = describeBffError(_err(status: 500));
      expect(parsed.errorDescription, isNull);
      expect(parsed.attemptsLeft, isNull);
    });
  });
}
