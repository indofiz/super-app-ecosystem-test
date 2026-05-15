import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../logging/auth_log.dart';
import '../network/dio_factory.dart';
import '../network/logging_interceptor.dart';
import '../../features/auth/domain/auth_repository.dart';
import '../../features/auth/domain/auth_session.dart';

/// Builds a Dio configured for `/api/*` calls that flow through nginx → Kong
/// → an upstream service. It does two jobs the features above should never
/// need to think about:
///
///   1. Attaches `Authorization: Bearer <internal-jwt>` on every request,
///      sourced from the current `AuthRepository` session.
///   2. On a single 401, calls `AuthRepository.refresh()` (deduped across
///      concurrent requests) and retries the original request once with the
///      new bearer. A second 401 propagates to the caller as a real error —
///      the auth bloc will see `session = null` via `sessionChanges` after
///      `refresh()` throws.
///
/// The client owns no state beyond the cached bearer; ownership of the
/// session itself stays in the repository, so log-out / session-change
/// behaviour remains driven by the bloc.
class ApiClient {
  ApiClient._(this.dio, this._sub);

  final Dio dio;
  final StreamSubscription<AuthSession?> _sub;

  factory ApiClient.create({
    required AppConfig config,
    required AuthRepository authRepository,
    AuthSession? initialSession,
    Dio? dio,
  }) {
    final client = dio ?? createDio(config: config);

    final tokenHolder = _TokenHolder(initialSession);
    final sub = authRepository.sessionChanges.listen(tokenHolder.set);

    client.interceptors.add(_AuthInterceptor(tokenHolder));
    client.interceptors.add(_RefreshInterceptor(
      dio: client,
      tokenHolder: tokenHolder,
      authRepository: authRepository,
    ));
    client.interceptors.add(httpLoggingInterceptor('http'));
    return ApiClient._(client, sub);
  }

  Future<void> dispose() async {
    await _sub.cancel();
    dio.close(force: true);
  }
}

class _TokenHolder {
  _TokenHolder(AuthSession? initial) : _session = initial;
  AuthSession? _session;

  String? get bearer => _session?.accessToken;
  void set(AuthSession? s) => _session = s;
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._tokens);
  final _TokenHolder _tokens;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final bearer = _tokens.bearer;
    if (bearer != null && !options.headers.containsKey('Authorization')) {
      options.headers['Authorization'] = 'Bearer $bearer';
    }
    handler.next(options);
  }
}

class _RefreshInterceptor extends Interceptor {
  _RefreshInterceptor({
    required this.dio,
    required _TokenHolder tokenHolder,
    required this.authRepository,
  }) : _tokens = tokenHolder;

  final Dio dio;
  final _TokenHolder _tokens;
  final AuthRepository authRepository;

  /// Dedupe across concurrent 401s: the first one starts the refresh, the
  /// rest await the same future.
  Completer<void>? _refreshing;

  static const _kRetriedExtra = '_apiClient.retried';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final status = err.response?.statusCode;
    final options = err.requestOptions;
    final alreadyRetried = options.extra[_kRetriedExtra] == true;
    if (status != 401 || alreadyRetried) {
      handler.next(err);
      return;
    }

    try {
      await _refreshOnce();
    } catch (refreshErr) {
      // Refresh failed — the repo has already emitted session=null via its
      // stream so the bloc will land back on unauthenticated. Propagate
      // the original 401 to the caller; their UI surfaces the error.
      authLog('http', 'refresh-on-401 failed: $refreshErr');
      handler.next(err);
      return;
    }

    final newBearer = _tokens.bearer;
    if (newBearer == null) {
      handler.next(err);
      return;
    }

    final retried = options.copyWith(
      headers: {...options.headers, 'Authorization': 'Bearer $newBearer'},
      extra: {...options.extra, _kRetriedExtra: true},
    );
    try {
      final response = await dio.fetch<dynamic>(retried);
      handler.resolve(response);
    } on DioException catch (retryErr) {
      handler.next(retryErr);
    }
  }

  Future<void> _refreshOnce() {
    final inflight = _refreshing;
    if (inflight != null) return inflight.future;
    final c = Completer<void>();
    _refreshing = c;
    Future(() async {
      try {
        await authRepository.refresh();
        c.complete();
      } catch (e) {
        c.completeError(e);
      } finally {
        _refreshing = null;
      }
    });
    return c.future;
  }
}
