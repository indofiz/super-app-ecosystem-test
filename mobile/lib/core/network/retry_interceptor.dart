import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/auth_log.dart';

/// Retries transient HTTP failures (audit-002 H-04).
///
/// Without this, a single 503 from nginx during a BFF reload — or a
/// TCP reset while the phone moves between cell towers — surfaces as
/// a failure to the user, even though the next attempt would have
/// succeeded. The existing 401-refresh dance handles only one failure
/// class; everything else used to propagate immediately.
///
/// Retry policy:
///   - Transport-level (timeouts + connectionError) → retry up to
///     [maxRetries] times.
///   - HTTP 502 / 503 / 504 (gateway / upstream-transient) → retry.
///   - Anything else (4xx, other 5xx, cancel) → propagate verbatim.
///
/// Backoff is exponential with jitter:
///   - attempt 1 after ~ baseDelay
///   - attempt 2 after ~ 2× baseDelay
///   - each delay gets up to 50% additive jitter so concurrent retries
///     from many clients don't synchronize ("thundering herd").
///
/// Mutating endpoints opt out per-call by setting
/// `Options(extra: {RetryInterceptor.kNoRetryExtra: true})`. Used by the
/// OTP-verify endpoints — without an idempotency key, retrying a
/// successful-but-late verify would burn the user's attempt counter.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    this.maxRetries = 2,
    this.baseDelay = const Duration(milliseconds: 200),
    math.Random? random,
  }) : _random = random ?? math.Random();

  /// The Dio whose interceptor chain this is part of — used to re-issue
  /// the original request via `dio.fetch(retried)`. Same pattern as
  /// `_RefreshInterceptor` in `core/http/api_client.dart`.
  final Dio dio;

  /// Maximum *additional* attempts after the first failure. `maxRetries=2`
  /// means up to 3 total attempts.
  final int maxRetries;

  /// Delay before the first retry. Subsequent retries double it.
  final Duration baseDelay;

  final math.Random _random;

  /// Per-request extra key used to suppress retries on a specific call.
  /// Mutating endpoints (verify-OTP) set this so we never repeat the
  /// state-changing request.
  static const String kNoRetryExtra = '_retry.disabled';

  /// Per-request extra key tracking how many retries have already been
  /// attempted. Survives across [Dio.fetch] reissues because the request
  /// extras are copied verbatim.
  static const String _kAttemptsExtra = '_retry.attempts';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;

    if (options.extra[kNoRetryExtra] == true) {
      handler.next(err);
      return;
    }
    if (!_isRetryable(err)) {
      handler.next(err);
      return;
    }
    final attempts = (options.extra[_kAttemptsExtra] as int?) ?? 0;
    if (attempts >= maxRetries) {
      if (kDebugMode) {
        authLog('retry', 'exhausted (${attempts + 1} attempts) '
            '${options.method} ${options.uri}');
      }
      handler.next(err);
      return;
    }

    final delay = _backoffDelay(attempts);
    if (kDebugMode) {
      authLog('retry', 'attempt ${attempts + 1} in ${delay.inMilliseconds}ms '
          '${options.method} ${options.uri} ← ${_describe(err)}');
    }
    await Future<void>.delayed(delay);

    final retried = options.copyWith(
      extra: {...options.extra, _kAttemptsExtra: attempts + 1},
    );
    try {
      final response = await dio.fetch<dynamic>(retried);
      handler.resolve(response);
    } on DioException catch (retryErr) {
      // Re-throw — if still retryable and we have attempts left, this
      // interceptor will re-enter onError; otherwise it falls through
      // to the next handler.
      handler.next(retryErr);
    }
  }

  /// Returns true for transient failures that another attempt might
  /// succeed on. Cancellation is never retried — it's a control-flow
  /// signal, not a failure.
  bool _isRetryable(DioException err) {
    if (err.type == DioExceptionType.cancel) return false;
    if (err.type == DioExceptionType.connectionTimeout) return true;
    if (err.type == DioExceptionType.receiveTimeout) return true;
    if (err.type == DioExceptionType.sendTimeout) return true;
    if (err.type == DioExceptionType.connectionError) return true;
    if (err.type == DioExceptionType.badResponse) {
      final status = err.response?.statusCode;
      // Only retry the gateway/upstream-transient codes. 500/501 may
      // indicate a deterministic server bug and re-issuing would just
      // hammer the server with the same bad request.
      return status == 502 || status == 503 || status == 504;
    }
    return false;
  }

  /// Exponential backoff with up to 50% additive jitter.
  Duration _backoffDelay(int attempt) {
    final baseMs = baseDelay.inMilliseconds * (1 << attempt);
    final jitter = (_random.nextDouble() * 0.5 * baseMs).round();
    return Duration(milliseconds: baseMs + jitter);
  }

  String _describe(DioException err) {
    if (err.type == DioExceptionType.badResponse) {
      return '${err.response?.statusCode}';
    }
    return err.type.name;
  }
}
