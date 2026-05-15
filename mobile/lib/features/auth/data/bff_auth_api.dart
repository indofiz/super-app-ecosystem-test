import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/auth_timings.dart';
import '../../../core/network/dio_factory.dart';
import '../../../core/network/logging_interceptor.dart';

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
///
/// Deliberately does NOT use the workspace-shared `ApiClient` (which
/// auto-attaches a bearer and retries on 401). `/auth/refresh` running
/// through a 401-retry loop would recurse forever, so this stack stays
/// minimal: shared timeouts + shared debug logging, nothing else.
class BffAuthApi {
  BffAuthApi({required this.config, Dio? dio})
      : _dio = dio ??
            createDio(
              config: config,
              extraHeaders: const {'Content-Type': 'application/json'},
            ) {
    // BFF error envelope is safe to log in debug — surfaces
    // `error_description` and `detail.attempts_left` for the integration team.
    _dio.interceptors.add(httpLoggingInterceptor('api', logErrorBody: true));
  }

  final AppConfig config;
  final Dio _dio;

  Future<void> dispose() async {
    _dio.close(force: true);
  }

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

  /// POST /auth/email/send-otp — 202 with `{delivery, expires_in}`, or
  /// 200 with `{verified: true}` if the email is already verified.
  Future<({String delivery, int expiresIn, bool alreadyVerified})>
      sendEmailOtp(String bearer) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/auth/email/send-otp',
      data: const <String, dynamic>{},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    final body = res.data ?? const {};
    return (
      delivery: (body['delivery'] as String?) ?? 'email',
      expiresIn:
          (body['expires_in'] as num?)?.toInt() ?? kOtpDefaultTtl.inSeconds,
      alreadyVerified: body['verified'] == true,
    );
  }

  /// POST /auth/email/verify-otp — 200 with a fresh session on success.
  Future<({String accessToken, String sessionId, int expiresIn})>
      verifyEmailOtp(String bearer, String code) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/auth/email/verify-otp',
      data: {'code': code},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    final body = res.data ?? const {};
    return (
      accessToken: body['access_token'] as String,
      sessionId: body['session_id'] as String,
      expiresIn: (body['expires_in'] as num).toInt(),
    );
  }

  /// POST /auth/phone/send-otp — 202 with `{delivery, expires_in}`, or
  /// 200 with `{verified: true}` if the phone is already verified.
  Future<({String delivery, int expiresIn, bool alreadyVerified})>
      sendPhoneOtp(String bearer, String phone) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/auth/phone/send-otp',
      data: {'phone': phone},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    final body = res.data ?? const {};
    return (
      delivery: (body['delivery'] as String?) ?? 'wa',
      expiresIn:
          (body['expires_in'] as num?)?.toInt() ?? kOtpDefaultTtl.inSeconds,
      alreadyVerified: body['verified'] == true,
    );
  }

  /// POST /auth/phone/verify-otp — 200 with a fresh session on success.
  Future<({String accessToken, String sessionId, int expiresIn})>
      verifyPhoneOtp(String bearer, String phone, String code) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/auth/phone/verify-otp',
      data: {'phone': phone, 'code': code},
      options: Options(headers: {'Authorization': 'Bearer $bearer'}),
    );
    final body = res.data ?? const {};
    return (
      accessToken: body['access_token'] as String,
      sessionId: body['session_id'] as String,
      expiresIn: (body['expires_in'] as num).toInt(),
    );
  }
}
