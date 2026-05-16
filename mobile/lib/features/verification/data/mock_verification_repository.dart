import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/config/auth_timings.dart';
import '../../auth/data/datasources/auth_local_datasource.dart';
import '../../auth/data/mock_jwt.dart';
import '../../auth/domain/auth_error_code.dart';
import '../../auth/domain/auth_repository.dart';
import '../../auth/domain/auth_session.dart';
import '../../auth/domain/jwt_claims.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_repository.dart';

/// In-app mock that mimics the BFF's OTP send/verify contract.
///
/// Source of truth for the verification flags is the current session JWT
/// — same as the real BFF. After a successful verify we mint a fresh
/// fake JWT with the new flag flipped to true and push it through
/// [AuthRepository.replaceSession]. Subsequent reads (e.g.
/// `getProfile()`) see the updated flags because they all decode the
/// stored token.
///
/// Dev console: any code other than `"123456"` yields
/// [VerificationErrorCode.otpInvalid] with `attemptsLeft=4`.
class MockVerificationRepository implements VerificationRepository {
  MockVerificationRepository({
    required this.authRepository,
    required AuthLocalDataSource localDataSource,
  }) : _local = localDataSource;

  final AuthRepository authRepository;
  final AuthLocalDataSource _local;

  // Mock does not honor cancellation — the in-flight delays are too
  // short to make cancellation observable. Real cancellation lives in
  // BffVerificationRepository.

  @override
  Future<Duration> sendEmailOtp({CancelToken? cancel}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return kOtpDefaultTtl;
  }

  @override
  Future<AuthSession> verifyEmailOtp(
    String code, {
    CancelToken? cancel,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code != '123456') {
      throw VerificationFailure(
        code: VerificationErrorCode.otpInvalid,
        attemptsLeft: 4,
        retryable: true,
      );
    }
    return _reissue(emailVerified: true);
  }

  @override
  Future<Duration> sendPhoneOtp({CancelToken? cancel}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // audit-003 M-03: no phone passed in — mirrors the real BFF, which
    // reads the citizen's number from the Keycloak profile. The mock
    // session already carries `phone_number` (seeded at login), so there
    // is nothing to cache here; verify just flips the verified flag.
    return kOtpDefaultTtl;
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String code, {CancelToken? cancel}) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code != '123456') {
      throw VerificationFailure(
        code: VerificationErrorCode.otpInvalid,
        attemptsLeft: 4,
        retryable: true,
      );
    }
    // audit-003 M-03: no phone on the wire — mirror the real BFF, which
    // resolves the bound number from its OTP record. sendPhoneOtp() cached
    // it onto the session, so carry that forward (no override here).
    return _reissue(phoneNumberVerified: true);
  }

  @override
  Future<void> dispose() async {
    // No owned resources beyond what the auth repo holds.
  }

  /// Mint a new fake session that carries forward the current verification
  /// state, then applies the supplied overrides. The result is persisted
  /// via the auth side so listeners see it.
  Future<AuthSession> _reissue({
    bool? emailVerified,
    bool? phoneNumberVerified,
  }) async {
    final current = await _local.read();
    if (current == null) {
      // Auth-side failure surfaced through the verification API — the
      // user wouldn't be on this screen without a session, so this is
      // primarily defensive.
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    final sub = JwtClaims.fromToken(current.accessToken).sub ?? 'mock-user';
    final session = AuthSession.fromToken(
      accessToken: mockJwt(
        sub: sub,
        emailVerified: emailVerified ?? current.emailVerified,
        phoneNumber: current.phoneNumber,
        phoneNumberVerified:
            phoneNumberVerified ?? current.phoneNumberVerified,
      ),
      sessionId: current.sessionId,
      expiresAt: DateTime.now().add(kMockSessionLifetime),
    );
    await authRepository.replaceSession(session);
    return session;
  }
}
