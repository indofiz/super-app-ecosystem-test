import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/core/network/retry_interceptor.dart';

/// Scripted HTTP adapter — pops planned outcomes off a queue per call.
/// Lets us simulate `[503, 503, 200]` style sequences deterministically.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<_Outcome> script;
  final List<RequestOptions> requestLog = [];
  int _next = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestLog.add(options);
    if (_next >= script.length) {
      throw StateError(
        'Adapter ran out of scripted outcomes at call ${_next + 1} '
        '(${options.method} ${options.uri})',
      );
    }
    final outcome = script[_next++];
    if (outcome.error != null) throw outcome.error!;
    return ResponseBody.fromString(
      outcome.body ?? '',
      outcome.status!,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Outcome {
  _Outcome.response(this.status, this.body) : error = null;
  _Outcome.error(this.error)
      : status = null,
        body = null;

  final int? status;
  final String? body;
  final DioException? error;
}

Dio _newDioWithRetry(_ScriptedAdapter adapter, {int maxRetries = 2}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://example.test',
      // Tight timeouts so a hung adapter would fail fast in tests, but
      // the adapter resolves synchronously so this is just defensive.
      connectTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(seconds: 1),
    ),
  );
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(RetryInterceptor(
    dio: dio,
    maxRetries: maxRetries,
    // Zero base delay so tests don't sleep.
    baseDelay: Duration.zero,
    random: math.Random(0),
  ));
  return dio;
}

void main() {
  group('RetryInterceptor', () {
    test('503 then 200 → resolves as 200 after one retry', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(503, '{"error":"unavailable"}'),
        _Outcome.response(200, '{"ok":true}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      final res = await dio.get<dynamic>('/x');

      expect(res.statusCode, 200);
      expect(adapter.requestLog, hasLength(2));
    });

    test('three 503s exhaust retries → caller sees the third failure',
        () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(503, '{}'),
        _Outcome.response(503, '{}'),
        _Outcome.response(503, '{}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 503)),
      );
      expect(adapter.requestLog, hasLength(3));
    });

    test('400 is NOT retried (client error)', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(400, '{"error":"bad_request"}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 400)),
      );
      expect(adapter.requestLog, hasLength(1));
    });

    test('500 is NOT retried (only 502/503/504)', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(500, '{"error":"server"}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 500)),
      );
      expect(adapter.requestLog, hasLength(1));
    });

    test('connectionError is retried as a transient transport failure',
        () async {
      final adapter = _ScriptedAdapter([
        _Outcome.error(DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        )),
        _Outcome.response(200, '{"ok":true}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      final res = await dio.get<dynamic>('/x');
      expect(res.statusCode, 200);
      expect(adapter.requestLog, hasLength(2));
    });

    test('cancel is never retried', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.error(DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.cancel,
        )),
      ]);
      final dio = _newDioWithRetry(adapter);

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      expect(adapter.requestLog, hasLength(1));
    });

    test('noRetry extra suppresses retries even on 503', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(503, '{}'),
      ]);
      final dio = _newDioWithRetry(adapter);

      await expectLater(
        dio.post<dynamic>(
          '/x',
          options: Options(
            extra: const {RetryInterceptor.kNoRetryExtra: true},
          ),
        ),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 503)),
      );
      expect(adapter.requestLog, hasLength(1));
    });

    test('maxRetries=0 disables retry but does not break the chain', () async {
      final adapter = _ScriptedAdapter([
        _Outcome.response(503, '{}'),
      ]);
      final dio = _newDioWithRetry(adapter, maxRetries: 0);

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requestLog, hasLength(1));
    });
  });
}
