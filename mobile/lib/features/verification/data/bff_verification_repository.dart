import 'package:dio/dio.dart';

import '../../../core/config/auth_timings.dart';
import '../../../core/logging/auth_log.dart';
import '../../../core/network/bff_error.dart';
import '../../../core/network/bff_parse.dart';
import '../../auth/data/datasources/auth_local_datasource.dart';
import '../../auth/domain/auth_repository.dart';
import '../../auth/domain/auth_session.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_repository.dart';
import 'datasources/verification_remote_datasource.dart';

final _log = authLogger('verify');

/// Real BFF-mediated verification repository.
///
/// Orchestrates three collaborators (audit-002 H-01):
///   - [VerificationRemoteDataSource] — `/auth/{email,phone}/{send,verify}-otp`.
///   - [AuthLocalDataSource] — current bearer / session (shared with the
///     auth feature; the verify flow uses the bearer to authorize the
///     request).
///   - [AuthRepository.replaceSession] — pushes the re-minted JWT back
///     through the auth side so the auth stack stays the single source of
///     truth for "the current session".
///
/// No direct `SecureStore` / `BffAuthApi` dependencies — those leaked
/// out as part of the H-01 cleanup.
class BffVerificationRepository implements VerificationRepository {
  BffVerificationRepository({
    required this.authRepository,
    required AuthLocalDataSource localDataSource,
    required VerificationRemoteDataSource remoteDataSource,
  })  : _local = localDataSource,
        _remote = remoteDataSource;

  final AuthRepository authRepository;
  final AuthLocalDataSource _local;
  final VerificationRemoteDataSource _remote;

  @override
  Future<Duration> sendEmailOtp({CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _remote.sendEmailOtp(
        bearer: stored.accessToken,
        cancel: cancel,
      );
      _log('sendEmailOtp: delivery=${res.delivery ?? 'email'} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn ?? kOtpDefaultTtl.inSeconds);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: VerificationErrorCode.sendOtpFailed);
    } on BffParseFailure catch (e) {
      throw _mapParse(e, fallback: VerificationErrorCode.sendOtpFailed);
    } on TypeError catch (e) {
      throw _mapTypeError(e, fallback: VerificationErrorCode.sendOtpFailed);
    }
  }

  @override
  Future<AuthSession> verifyEmailOtp(String code, {CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      final res = await _remote.verifyEmailOtp(
        bearer: stored.accessToken,
        code: code,
        cancel: cancel,
      );
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
    } on BffParseFailure catch (e) {
      throw _mapParse(e, fallback: VerificationErrorCode.verifyOtpFailed);
    } on TypeError catch (e) {
      throw _mapTypeError(e, fallback: VerificationErrorCode.verifyOtpFailed);
    }
  }

  @override
  Future<Duration> sendPhoneOtp({CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      // audit-003 M-03: no phone on the wire — the BFF resolves the
      // citizen's number from their Keycloak profile, same as email.
      final res = await _remote.sendPhoneOtp(
        bearer: stored.accessToken,
        cancel: cancel,
      );
      _log('sendPhoneOtp: delivery=${res.delivery ?? 'wa'} '
          'alreadyVerified=${res.alreadyVerified}');
      return Duration(seconds: res.expiresIn ?? kOtpDefaultTtl.inSeconds);
    } on DioException catch (e) {
      throw _mapDio(e, fallback: VerificationErrorCode.sendOtpFailed);
    } on BffParseFailure catch (e) {
      throw _mapParse(e, fallback: VerificationErrorCode.sendOtpFailed);
    } on TypeError catch (e) {
      throw _mapTypeError(e, fallback: VerificationErrorCode.sendOtpFailed);
    }
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String code, {CancelToken? cancel}) async {
    final stored = await _local.read();
    if (stored == null) {
      throw VerificationFailure(code: VerificationErrorCode.notAuthenticated);
    }
    try {
      // audit-003 M-03: no `phone` on the wire — the BFF resolves the
      // bound number from its own OTP record. The bearer + code are the
      // only things the client asserts.
      final res = await _remote.verifyPhoneOtp(
        bearer: stored.accessToken,
        code: code,
        cancel: cancel,
      );
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
    } on BffParseFailure catch (e) {
      throw _mapParse(e, fallback: VerificationErrorCode.verifyOtpFailed);
    } on TypeError catch (e) {
      throw _mapTypeError(e, fallback: VerificationErrorCode.verifyOtpFailed);
    }
  }

  @override
  Future<void> dispose() async {
    await _remote.dispose();
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

  /// BFF contract drift — fall back to a generic failure with the parse
  /// detail in the diagnostic for logs (audit-002 C-01). Caller picks the
  /// fallback code so send vs verify show the right localized copy.
  VerificationFailure _mapParse(
    BffParseFailure e, {
    required VerificationErrorCode fallback,
  }) {
    _log('BFF contract violation → $e');
    return VerificationFailure(
      code: fallback,
      diagnostic: '$e',
      cause: e,
    );
  }

  /// Defence in depth for any future call site that bypasses
  /// `bff_parse.dart` and lets a raw cast escape (audit-002 C-01).
  VerificationFailure _mapTypeError(
    TypeError e, {
    required VerificationErrorCode fallback,
  }) {
    _log('unexpected TypeError → $e');
    return VerificationFailure(
      code: fallback,
      diagnostic: 'TypeError: $e',
      cause: e,
    );
  }
}
