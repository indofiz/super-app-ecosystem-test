import 'package:dio/dio.dart';

import '../../../auth/data/dto/send_otp_response_dto.dart';
import '../../../auth/data/dto/verify_otp_response_dto.dart';
import '../bff_verification_api.dart';

/// Remote data source for the verification feature (audit-002 H-01).
///
/// Wraps [BffVerificationApi] so the repository depends on a data-source
/// abstraction rather than on the HTTP wire detail. Stateless: callers
/// pass the bearer (and the phone number, for the phone channel)
/// explicitly. The repo holds the auth-side local data source and pipes
/// the persisted bearer through here.
///
/// Every method accepts an optional [CancelToken] (audit-002 H-02). The
/// verification bloc holds a per-channel token; on bloc close those
/// tokens are cancelled, which aborts the in-flight HTTP request and
/// surfaces as a domain `CancelledException`.
///
/// Owns the underlying [BffVerificationApi] (constructed externally) and
/// disposes it on [dispose].
class VerificationRemoteDataSource {
  VerificationRemoteDataSource({required BffVerificationApi api}) : _api = api;

  final BffVerificationApi _api;

  Future<SendOtpResponseDto> sendEmailOtp({
    required String bearer,
    CancelToken? cancel,
  }) =>
      _api.sendEmailOtp(bearer, cancel: cancel);

  Future<VerifyOtpResponseDto> verifyEmailOtp({
    required String bearer,
    required String code,
    CancelToken? cancel,
  }) =>
      _api.verifyEmailOtp(bearer, code, cancel: cancel);

  Future<SendOtpResponseDto> sendPhoneOtp({
    required String bearer,
    required String phone,
    CancelToken? cancel,
  }) =>
      _api.sendPhoneOtp(bearer, phone, cancel: cancel);

  Future<VerifyOtpResponseDto> verifyPhoneOtp({
    required String bearer,
    required String phone,
    required String code,
    CancelToken? cancel,
  }) =>
      _api.verifyPhoneOtp(bearer, phone, code, cancel: cancel);

  Future<void> dispose() => _api.dispose();
}
