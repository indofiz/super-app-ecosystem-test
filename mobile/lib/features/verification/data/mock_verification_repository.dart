import 'dart:async';

import '../../../core/config/auth_timings.dart';
import '../../../core/storage/secure_store.dart';
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
    required this.secureStore,
  });

  final AuthRepository authRepository;
  final SecureStore secureStore;

  @override
  Future<Duration> sendEmailOtp() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return kOtpDefaultTtl;
  }

  @override
  Future<AuthSession> verifyEmailOtp(String code) async {
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
  Future<Duration> sendPhoneOtp(String phone) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // Cache the phone on the current session so a subsequent verify
    // (which doesn't re-pass the number through the JWT) can use it.
    await _reissue(phoneNumber: phone);
    return kOtpDefaultTtl;
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String phone, String code) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code != '123456') {
      throw VerificationFailure(
        code: VerificationErrorCode.otpInvalid,
        attemptsLeft: 4,
        retryable: true,
      );
    }
    return _reissue(phoneNumber: phone, phoneNumberVerified: true);
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
    String? phoneNumber,
    bool? phoneNumberVerified,
  }) async {
    final stored = await secureStore.readSession();
    if (stored == null) {
      // Auth-side failure surfaced through the verification API — the
      // user wouldn't be on this screen without a session, so this is
      // primarily defensive.
      throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    }
    final current = JwtClaims.fromToken(stored.accessToken);
    final session = AuthSession.fromToken(
      accessToken: mockJwt(
        sub: current.sub ?? 'mock-user',
        emailVerified: emailVerified ?? current.emailVerified,
        phoneNumber: phoneNumber ?? current.phoneNumber,
        phoneNumberVerified:
            phoneNumberVerified ?? current.phoneNumberVerified,
      ),
      sessionId: stored.sessionId,
      expiresAt: DateTime.now().add(kMockSessionLifetime),
    );
    await authRepository.replaceSession(session);
    return session;
  }
}
