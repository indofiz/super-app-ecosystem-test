import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../core/storage/secure_store.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';

/// In-app mock that mimics the BFF contract. Used while the BFF is not
/// yet deployed so the rest of the app can be developed end-to-end.
///
/// Behaviour:
///  - login(): simulates a deeplink round-trip and returns a fake session.
///  - refresh(): rotates the access token, keeps the session_id stable.
///  - logout(): clears storage.
///  - send*Otp(): no-op delay; the dev console can use "123456" to verify.
///  - verify*Otp(): "123456" succeeds; any other code yields OtpInvalidFailure.
///
/// Swap to BffAuthRepository by flipping USE_MOCK_AUTH=false in .env.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({required this.secureStore});

  final SecureStore secureStore;
  final _controller = StreamController<AuthSession?>.broadcast();
  final _rng = Random.secure();

  bool _emailVerified = false;
  bool _phoneVerified = false;
  String? _phoneNumber;

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    final stored = await secureStore.readSession();
    if (stored == null) return null;
    final session = AuthSession.fromToken(
      accessToken: stored.accessToken,
      sessionId: stored.sessionId,
      expiresAt: stored.expiresAt,
    );
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> login() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // Reset verification state on each new login so the banner is visible
    // from a fresh install — exercises the verification flow in dev.
    _emailVerified = false;
    _phoneVerified = false;
    _phoneNumber = null;
    final session = AuthSession.fromToken(
      accessToken: _fakeJwt(sub: 'mock-user-${_rng.nextInt(9999)}'),
      sessionId: _randomToken(32),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
    );
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> refresh() async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('No session to refresh.');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final session = AuthSession.fromToken(
      accessToken: _fakeJwt(sub: 'mock-user-refreshed'),
      sessionId: stored.sessionId,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
    );
    _controller.add(session);
    return session;
  }

  @override
  Future<void> logout() async {
    await secureStore.clear();
    _controller.add(null);
  }

  @override
  Future<UserProfile> getProfile() async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('Not authenticated');
    return UserProfile(
      sub: 'mock-user-${_rng.nextInt(9999)}',
      username: 'mock.user',
      email: 'mock@example.test',
      emailVerified: _emailVerified,
      phoneNumber: _phoneNumber,
      phoneNumberVerified: _phoneVerified,
      roles: const ['citizen'],
      expiresAt: stored.expiresAt,
    );
  }

  @override
  Future<Duration> sendEmailOtp() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const Duration(seconds: 300);
  }

  @override
  Future<AuthSession> verifyEmailOtp(String code) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code != '123456') {
      throw OtpInvalidFailure(attemptsLeft: 4);
    }
    _emailVerified = true;
    return _reissue();
  }

  @override
  Future<Duration> sendPhoneOtp(String phone) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _phoneNumber = phone;
    return const Duration(seconds: 300);
  }

  @override
  Future<AuthSession> verifyPhoneOtp(String phone, String code) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (code != '123456') {
      throw OtpInvalidFailure(attemptsLeft: 4);
    }
    _phoneVerified = true;
    _phoneNumber = phone;
    return _reissue();
  }

  /// Re-mint a fake session that reflects the current verification state.
  /// Mirrors what the real BFF does inside its verify-OTP handlers.
  Future<AuthSession> _reissue() async {
    final stored = await secureStore.readSession();
    final session = AuthSession.fromToken(
      accessToken: _fakeJwt(
        sub: 'mock-user-verified',
        emailVerified: _emailVerified,
        phoneNumber: _phoneNumber,
        phoneNumberVerified: _phoneVerified,
      ),
      sessionId: stored?.sessionId ?? _randomToken(32),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
    );
    _controller.add(session);
    return session;
  }

  String _randomToken(int bytes) {
    final values = List<int>.generate(bytes, (_) => _rng.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  String _fakeJwt({
    required String sub,
    bool emailVerified = false,
    String? phoneNumber,
    bool phoneNumberVerified = false,
  }) {
    String b64(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final header = b64({'alg': 'none', 'typ': 'JWT'});
    final payload = b64({
      'iss': 'mock-bff',
      'sub': sub,
      'name': 'Mock User',
      'preferred_username': sub,
      'email': 'mock@example.test',
      'email_verified': emailVerified,
      if (phoneNumber != null) 'phone_number': phoneNumber,
      'phone_number_verified': phoneNumberVerified,
      'realm': 'pangkalpinang',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
    });
    return '$header.$payload.';
  }
}
