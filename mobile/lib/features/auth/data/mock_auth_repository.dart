import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../../core/config/auth_timings.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_error_code.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import 'mock_jwt.dart';

/// In-app mock that mimics the BFF contract for the **auth** half:
/// login / refresh / logout / profile / session-stream. The verification
/// half (OTP send/verify) lives in [MockVerificationRepository] under the
/// verification feature.
///
/// Behaviour:
///  - login(): simulates a deeplink round-trip, returns a fresh session
///    with both verified flags false (so the verification banner shows).
///  - refresh(): rotates the access token; keeps session_id stable.
///  - logout(): clears storage.
///  - getProfile(): derives all fields from the JWT-decoded session, so
///    it stays in sync with whatever the verification mock minted last.
///
/// Swap to [BffAuthRepository] by flipping `USE_MOCK_AUTH=false` in `.env`.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({required this.secureStore});

  final SecureStore secureStore;
  final _controller = StreamController<AuthSession?>.broadcast();
  final _rng = Random.secure();

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    final stored = await secureStore.readSession();
    if (stored == null) return null;
    final session = AuthSession.fromStored(stored);
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> login() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final session = AuthSession.fromToken(
      accessToken: mockJwt(sub: 'mock-user-${_rng.nextInt(9999)}'),
      sessionId: _randomToken(32),
      expiresAt: DateTime.now().add(kMockSessionLifetime),
    );
    await secureStore.writeSession(session.toStored());
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> refresh() async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Carry forward the verification flags from the current session — a
    // refresh must not "un-verify" the user.
    final current = AuthSession.fromStored(stored);
    final session = AuthSession.fromToken(
      accessToken: mockJwt(
        sub: 'mock-user-refreshed',
        emailVerified: current.emailVerified,
        phoneNumber: current.phoneNumber,
        phoneNumberVerified: current.phoneNumberVerified,
      ),
      sessionId: stored.sessionId,
      expiresAt: DateTime.now().add(kMockSessionLifetime),
    );
    await secureStore.writeSession(session.toStored());
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
    if (stored == null) throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    final session = AuthSession.fromStored(stored);
    return UserProfile(
      sub: 'mock-user-${_rng.nextInt(9999)}',
      username: 'mock.user',
      email: session.email ?? 'mock@example.test',
      emailVerified: session.emailVerified,
      phoneNumber: session.phoneNumber,
      phoneNumberVerified: session.phoneNumberVerified,
      roles: const ['citizen'],
      expiresAt: stored.expiresAt,
    );
  }

  @override
  Future<void> replaceSession(AuthSession session) async {
    await secureStore.writeSession(session.toStored());
    _controller.add(session);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  String _randomToken(int bytes) {
    final values = List<int>.generate(bytes, (_) => _rng.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }
}
