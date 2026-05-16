import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/bff_parse.dart';
import '../../../core/network/cancelled_exception.dart';
import '../../../core/network/dio_factory.dart';
import '../../../core/network/logging_interceptor.dart';
import '../../../core/network/pretty_logging_interceptor.dart';
import 'dto/me_response_dto.dart';
import 'dto/refresh_response_dto.dart';

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
///                       -> {access_token, expires_in, session_id?}
///   POST /auth/logout   hdr: `Authorization: Bearer ...`
///                       body: {"session_id": "..."}
///                       -> 204
///   GET  /auth/me       hdr: `Authorization: Bearer ...`
///                       -> {sub, username, email, roles, expiresAt, ...}
///
/// The OTP send/verify endpoints live in [BffVerificationApi] under the
/// verification feature (audit-002 H-01 — split out so the verification
/// repo no longer imports across feature boundaries).
///
/// Deliberately does NOT use the workspace-shared `ApiClient` (which
/// auto-attaches a bearer and retries on 401). `/auth/refresh` running
/// through a 401-retry loop would recurse forever, so this stack stays
/// minimal: shared timeouts + shared debug logging, nothing else.
///
/// Return contract (audit-002 H-03): every method returns a typed DTO,
/// parsed by the DTO's `fromJson` via `bff_parse.dart`. Contract drift
/// surfaces as a [BffParseFailure] at the DTO boundary, never as a raw
/// `TypeError` further up the stack.
class BffAuthApi {
  BffAuthApi({required this.config, Dio? dio})
      : _dio = dio ??
            createDio(
              config: config,
              extraHeaders: const {'Content-Type': 'application/json'},
              withRetry: true,
            ) {
    // audit-004 H-03: log only the BFF envelope discriminators
    // (`error` + `attempts_left`), never the full body. `error_description`
    // can echo user input (verify-OTP) and was previously visible to any
    // adb-connected device.
    _dio.interceptors.add(
      httpLoggingInterceptor('api', logBffErrorEnvelope: true),
    );
    final pretty = prettyHttpLoggingInterceptor(config);
    if (pretty != null) _dio.interceptors.add(pretty);
  }

  final AppConfig config;
  final Dio _dio;

  Future<void> dispose() async {
    _dio.close(force: true);
  }

  Future<RefreshResponseDto> refresh({
    required String sessionId,
    required String bearer,
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'session_id': sessionId},
          options: Options(headers: {'Authorization': 'Bearer $bearer'}),
          cancelToken: cancel,
        );
        return RefreshResponseDto.fromJson(requireBody(res, '/auth/refresh'));
      });

  Future<void> logout({
    required String sessionId,
    required String bearer,
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        await _dio.post(
          '/auth/logout',
          data: {'session_id': sessionId},
          options: Options(headers: {'Authorization': 'Bearer $bearer'}),
          cancelToken: cancel,
        );
      });

  Future<MeResponseDto> getMe(String bearer, {CancelToken? cancel}) =>
      withCancelTranslation(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/auth/me',
          options: Options(headers: {'Authorization': 'Bearer $bearer'}),
          cancelToken: cancel,
        );
        return MeResponseDto.fromJson(requireBody(res, '/auth/me'));
      });
}
