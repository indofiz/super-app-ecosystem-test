import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/network/bff_error.dart';
import '../../../core/storage/secure_store.dart';
import '../../auth/data/bff_auth_api.dart';
import '../../auth/domain/auth_repository.dart';
import '../../auth/domain/auth_session.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_repository.dart';

final _log = authLogger('verify');

/// Real BFF-mediated verification repository.
///
/// Reads the current bearer + session_id from [SecureStore], hits
/// `/auth/{email,phone}/{send,verify}-otp`, and on a successful verify
/// pushes the new session back through [AuthRepository.replaceSession]
/// so the auth stack stays the single source of truth.
class BffVerificationRepository implements VerificationRepository {
  BffVerificationRepository({
    required this.config,
    required this.authRepository,
    required this.secureStore,
    BffAuthApi? api,
  })  : _ownsApi = api == null,
        _api = api ?? BffAuthApi(config: config);

  final AppConfig config;
  final AuthRepository authRepository;
  final SecureStore secureStore;
  final BffAuthApi _api;
  final bool _ownsApi;

  @override
  Future<Duration> sendEmailOtp() async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _api.sendEmailOtp(stored.accessToken);
      _log('sendEmailOtp: delivery=${res.delivery} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: VerificationErrorCode.sendOtpFailed);
    }
  }

  @override
  Future<AuthSession> verifyEmailOtp(String code) async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _api.verifyEmailOtp(stored.accessToken, code);
      final session = AuthSession.fromToken(
        accessToken: res.accessToken,
        sessionId: res.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await authRepository.replaceSession(session);
      _log('verifyEmailOtp: SUCCESS');
      return session;
    } on DioException catch (e) {
      throw _mapVerifyDio(e);
    }
  }

  @override
  Future<Duration> sendPhoneOtp(String phone) async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _api.sendPhoneOtp(stored.accessToken, phone);
      _log('sendPhoneOtp: delivery=${res.delivery} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: VerificationErrorCode.sendOtpFailed);
    }
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String phone, String code) async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _api.verifyPhoneOtp(stored.accessToken, phone, code);
      final session = AuthSession.fromToken(
        accessToken: res.accessToken,
        sessionId: res.sessionId,
        expiresAt: DateTime.now().add(Duration(seconds: res.expiresIn)),
      );
      await authRepository.replaceSession(session);
      _log('verifyPhoneOtp: SUCCESS');
      return session;
    } on DioException catch (e) {
      throw _mapVerifyDio(e);
    }
  }

  @override
  Future<void> dispose() async {
    if (_ownsApi) await _api.dispose();
  }

  /// BFF error vocabulary on verify:
  ///   410 → otpExpired (record expired or already consumed)
  ///   422 + attempts_left>0 → otpInvalid
  ///   422 + attempts_left==0 → otpExhausted
  ///   anything else → verifyOtpFailed
  VerificationFailure _mapVerifyDio(DioException e) {
    final info = describeBffError(e);
    if (info.statusCode == 410) {
      return VerificationFailure(
        code: VerificationErrorCode.otpExpired,
        cause: e,
      );
    }
    if (info.statusCode == 422) {
      final attempts = info.attemptsLeft ?? 0;
      return VerificationFailure(
        code: attempts > 0
            ? VerificationErrorCode.otpInvalid
            : VerificationErrorCode.otpExhausted,
        attemptsLeft: attempts,
        cause: e,
        retryable: attempts > 0,
      );
    }
    return _mapDio(e, fallback: VerificationErrorCode.verifyOtpFailed);
  }

  VerificationFailure _mapDio(
    DioException e, {
    required VerificationErrorCode fallback,
  }) {
    final info = describeBffError(e);
    return VerificationFailure(
      code: info.isTimeout ? VerificationErrorCode.network : fallback,
      diagnostic: info.errorDescription,
      cause: e,
      retryable: info.isTimeout,
    );
  }
}
