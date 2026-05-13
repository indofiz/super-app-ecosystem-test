import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/auth_log.dart';

void _log(String msg) => authLog('api', msg);

/// Thin HTTP client for the BFF auth endpoints.
///
/// Endpoints (all routed through nginx at config.bffBaseUrl). Since BFF
/// IMPROVEMENT_PLAN §2.1 landed, all three of refresh/logout/me require a
/// `Authorization: Bearer <internal-jwt>` whose `sid` claim matches the
/// session_id sent in the body. /refresh additionally tolerates a bearer
/// expired by up to 24h (so a returning user doesn't have to re-auth).
///
///   POST /auth/refresh  hdr: `Authorization: Bearer ...`
///                       body: {"session_id": "..."}
///                       -> {access_token, expires_in, session_id}
///   POST /auth/logout   hdr: `Authorization: Bearer ...`
///                       body: {"session_id": "..."}
///                       -> 204
///   GET  /auth/me       hdr: `Authorization: Bearer ...`
///                       -> {sub, username, email, roles, expiresAt}
class BffAuthApi {
  BffAuthApi({required this.config, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: config.bffBaseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Content-Type': 'application/json'},
            )) {
    if (kDebugMode) {
      _dio.interceptors.add(InterceptorsWrapper(
        onRequest: (o, h) {
          _log('→ ${o.method} ${o.uri}');
          h.next(o);
        },
        onResponse: (r, h) {
          _log('← ${r.statusCode} ${r.requestOptions.uri}');
          h.next(r);
        },
        onError: (e, h) {
          _log('✗ ${e.requestOptions.method} ${e.requestOptions.uri} — ${e.response?.statusCode} ${e.message}');
          if (e.response?.data != null) _log('  body=${e.response!.data}');
          h.next(e);
        },
      ));
    }
  }

  final AppConfig config;
  final Dio _dio;

  Future<({String accessToken, String sessionId, int expiresIn})> refresh({
    required String sessionId,
    required String bearer,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/auth/refresh',
      data: {'session_id': sessionId},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    final body = res.data ?? const {};
    return (
      accessToken: body['access_token'] as String,
      sessionId: (body['session_id'] as String?) ?? sessionId,
      expiresIn: (body['expires_in'] as num).toInt(),
    );
  }

  Future<void> logout({required String sessionId, required String bearer}) async {
    await _dio.post(
      '/auth/logout',
      data: {'session_id': sessionId},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
  }

  Future<Map<String, dynamic>> getMe(String bearer) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/auth/me',
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    return res.data ?? const {};
  }
}
