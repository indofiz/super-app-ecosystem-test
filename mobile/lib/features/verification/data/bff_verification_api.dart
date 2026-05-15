import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/bff_parse.dart';
import '../../../core/network/cancelled_exception.dart';
import '../../../core/network/dio_factory.dart'
    show createDio, kHttpReceiveTimeoutSlow;
import '../../../core/network/logging_interceptor.dart';
import '../../../core/network/retry_interceptor.dart';
import '../../auth/data/dto/send_otp_response_dto.dart';
import '../../auth/data/dto/verify_otp_response_dto.dart';

/// Thin HTTP client for the BFF verification (OTP) endpoints.
///
/// Lives in the verification feature so the verification repo no longer
/// reaches into `features/auth/data/` for its API — that cross-feature
/// import was the visible symptom of the missing feature-level data
/// boundary (audit-002 H-01).
///
/// The OTP DTOs (`SendOtpResponseDto` / `VerifyOtpResponseDto`) stay
/// under `features/auth/data/dto/` for now — they describe the BFF auth
/// surface and `AuthSession` is the post-verify session type. Moving the
/// DTOs is out of scope for Phase 2; the import here is one-way and
/// data-only, which is fine.
///
/// Endpoints (routed through nginx at config.bffBaseUrl):
///   POST /auth/email/send-otp     hdr: bearer  body: {}              → 202 / 200
///   POST /auth/email/verify-otp   hdr: bearer  body: {code}          → 200 {access_token,…}
///   POST /auth/phone/send-otp     hdr: bearer  body: {phone}         → 202 / 200
///   POST /auth/phone/verify-otp   hdr: bearer  body: {phone,code}    → 200 {access_token,…}
///
/// Like [BffAuthApi], deliberately does NOT use `ApiClient` (whose
/// refresh-on-401 loop would recurse if a verify ever 401s mid-session
/// rotation). Shared timeouts + shared debug logging, nothing else.
class BffVerificationApi {
  BffVerificationApi({required this.config, Dio? dio})
      : _dio = dio ??
            createDio(
              config: config,
              extraHeaders: const {'Content-Type': 'application/json'},
              withRetry: true,
            ) {
    // audit-004 H-03: log only the BFF envelope discriminators
    // (`error` + `attempts_left`), never the full body. The verify-OTP
    // path is the worst offender — `error_description` echoes the user's
    // typed code on a few error_code paths.
    _dio.interceptors.add(
      httpLoggingInterceptor('verify', logBffErrorEnvelope: true),
    );
  }

  final AppConfig config;
  final Dio _dio;

  Future<void> dispose() async {
    _dio.close(force: true);
  }

  /// POST /auth/email/send-otp — 202 with `{delivery, expires_in}`, or
  /// 200 with `{verified: true}` if the email is already verified.
  ///
  /// Tagged `noRetry` (audit-002 H-04) — the BFF dispatches an email
  /// via SMTP as a side effect, so a transient 5xx between "BFF queued
  /// the email" and "client got the response" would otherwise produce
  /// a duplicate delivery to the user. The UI exposes "Kirim ulang"
  /// for manual retry instead.
  Future<SendOtpResponseDto> sendEmailOtp(
    String bearer, {
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/email/send-otp',
          data: const <String, dynamic>{},
          options: Options(
            headers: {'Authorization': 'Bearer $bearer'},
            extra: const {RetryInterceptor.kNoRetryExtra: true},
            // audit-004 M-03: SMTP delivery can take >15 s under load.
            receiveTimeout: kHttpReceiveTimeoutSlow,
            sendTimeout: kHttpReceiveTimeoutSlow,
          ),
          cancelToken: cancel,
        );
        return SendOtpResponseDto.fromJson(
          requireBody(res, '/auth/email/send-otp'),
        );
      });

  /// POST /auth/email/verify-otp — 200 with a fresh session on success.
  ///
  /// Tagged `noRetry` (audit-002 H-04) — the BFF tracks attempts on the
  /// OTP record, so a transient 5xx between "BFF consumed the attempt"
  /// and "client got the response" would otherwise have the retry
  /// burn a second attempt for what was already a successful submit.
  Future<VerifyOtpResponseDto> verifyEmailOtp(
    String bearer,
    String code, {
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/email/verify-otp',
          data: {'code': code},
          options: Options(
            headers: {'Authorization': 'Bearer $bearer'},
            extra: const {RetryInterceptor.kNoRetryExtra: true},
          ),
          cancelToken: cancel,
        );
        return VerifyOtpResponseDto.fromJson(
          requireBody(res, '/auth/email/verify-otp'),
        );
      });

  /// POST /auth/phone/send-otp — 202 with `{delivery, expires_in}`, or
  /// 200 with `{verified: true}` if the phone is already verified.
  ///
  /// Tagged `noRetry` for the same reason as [sendEmailOtp]: Fonnte
  /// dispatches a WhatsApp message as a side effect.
  Future<SendOtpResponseDto> sendPhoneOtp(
    String bearer,
    String phone, {
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/phone/send-otp',
          data: {'phone': phone},
          options: Options(
            headers: {'Authorization': 'Bearer $bearer'},
            extra: const {RetryInterceptor.kNoRetryExtra: true},
            // audit-004 M-03: Fonnte's p99 exceeds 20 s during carrier
            // saturation. A 15 s cap surfaces a delivered OTP as failure.
            receiveTimeout: kHttpReceiveTimeoutSlow,
            sendTimeout: kHttpReceiveTimeoutSlow,
          ),
          cancelToken: cancel,
        );
        return SendOtpResponseDto.fromJson(
          requireBody(res, '/auth/phone/send-otp'),
        );
      });

  /// POST /auth/phone/verify-otp — 200 with a fresh session on success.
  ///
  /// Tagged `noRetry` for the same reason as [verifyEmailOtp].
  Future<VerifyOtpResponseDto> verifyPhoneOtp(
    String bearer,
    String phone,
    String code, {
    CancelToken? cancel,
  }) =>
      withCancelTranslation(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/auth/phone/verify-otp',
          data: {'phone': phone, 'code': code},
          options: Options(
            headers: {'Authorization': 'Bearer $bearer'},
            extra: const {RetryInterceptor.kNoRetryExtra: true},
          ),
          cancelToken: cancel,
        );
        return VerifyOtpResponseDto.fromJson(
          requireBody(res, '/auth/phone/verify-otp'),
        );
      });
}
