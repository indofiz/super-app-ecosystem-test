import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/api_failure.dart';
import 'package:smart_app_test/core/network/bff_parse.dart';

DioException _err({
  int? status,
  Object? body,
  DioExceptionType type = DioExceptionType.badResponse,
}) {
  final req = RequestOptions(path: '/api/profile');
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
  group('mapDioToApiFailure - transport-level', () {
    test('connectionTimeout → network + retryable', () {
      final f = mapDioToApiFailure(
        _err(type: DioExceptionType.connectionTimeout),
      );
      expect(f.code, ApiErrorCode.network);
      expect(f.retryable, isTrue);
    });

    test('receiveTimeout → network + retryable', () {
      final f = mapDioToApiFailure(
        _err(type: DioExceptionType.receiveTimeout),
      );
      expect(f.code, ApiErrorCode.network);
      expect(f.retryable, isTrue);
    });

    test('sendTimeout → network + retryable', () {
      final f = mapDioToApiFailure(_err(type: DioExceptionType.sendTimeout));
      expect(f.code, ApiErrorCode.network);
      expect(f.retryable, isTrue);
    });

    test('connectionError (DNS/TCP reset) → network + retryable', () {
      final f = mapDioToApiFailure(
        _err(type: DioExceptionType.connectionError),
      );
      expect(f.code, ApiErrorCode.network);
      expect(f.retryable, isTrue);
    });
  });

  group('mapDioToApiFailure - HTTP status', () {
    test('401 → unauthorized, not retryable', () {
      final f = mapDioToApiFailure(_err(status: 401));
      expect(f.code, ApiErrorCode.unauthorized);
      expect(f.retryable, isFalse);
    });

    test('403 → forbidden', () {
      expect(
        mapDioToApiFailure(_err(status: 403)).code,
        ApiErrorCode.forbidden,
      );
    });

    test('404 → notFound', () {
      expect(
        mapDioToApiFailure(_err(status: 404)).code,
        ApiErrorCode.notFound,
      );
    });

    test('400 / 422 → badRequest', () {
      expect(
        mapDioToApiFailure(_err(status: 400)).code,
        ApiErrorCode.badRequest,
      );
      expect(
        mapDioToApiFailure(_err(status: 422)).code,
        ApiErrorCode.badRequest,
      );
    });

    test('500 / 502 / 503 / 504 → server + retryable', () {
      for (final s in [500, 502, 503, 504]) {
        final f = mapDioToApiFailure(_err(status: s));
        expect(f.code, ApiErrorCode.server, reason: 'status=$s');
        expect(f.retryable, isTrue, reason: 'status=$s should retry');
      }
    });
  });

  group('mapDioToApiFailure - diagnostic capture', () {
    test('lifts error_description into diagnostic for logging', () {
      final f = mapDioToApiFailure(_err(
        status: 503,
        body: {'error_description': 'upstream connect timeout'},
      ));
      expect(f.diagnostic, 'upstream connect timeout');
    });

    test('null body leaves diagnostic null', () {
      expect(mapDioToApiFailure(_err(status: 500)).diagnostic, isNull);
    });
  });

  group('mapParseToApiFailure', () {
    test('translates to parse code with the failure stringified', () {
      final f = mapParseToApiFailure(BffParseFailure('access_token', 'missing'));
      expect(f.code, ApiErrorCode.parse);
      expect(f.diagnostic, contains('access_token'));
      expect(f.diagnostic, contains('missing'));
    });
  });
}
