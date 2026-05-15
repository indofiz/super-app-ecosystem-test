import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/cancelled_exception.dart';

void main() {
  group('withCancelTranslation', () {
    test('returns the body value on success', () async {
      final result = await withCancelTranslation<int>(() async => 42);
      expect(result, 42);
    });

    test('translates DioException(type: cancel) into CancelledException',
        () async {
      await expectLater(
        withCancelTranslation<void>(() async {
          throw DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.cancel,
          );
        }),
        throwsA(isA<CancelledException>()),
      );
    });

    test('non-cancel DioException propagates verbatim', () async {
      final original = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionTimeout,
      );
      await expectLater(
        withCancelTranslation<void>(() async => throw original),
        throwsA(same(original)),
      );
    });

    test('non-Dio exceptions propagate verbatim', () async {
      await expectLater(
        withCancelTranslation<void>(() async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
    });
  });
}
