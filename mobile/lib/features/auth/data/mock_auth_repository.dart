import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../../core/config/auth_timings.dart';
import '../domain/auth_error_code.dart';
import '../domain/auth_repository.dart';
import '../domain/auth_session.dart';
import 'datasources/auth_local_datasource.dart';
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
/// Uses the same [AuthLocalDataSource] abstraction as [BffAuthRepository]
/// (audit-002 H-01) so both impls share the persistence boundary by
/// construction.
///
/// Swap to [BffAuthRepository] by flipping `USE_MOCK_AUTH=false` in `.env`.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({required AuthLocalDataSource localDataSource})
      : _local = localDataSource;

  final AuthLocalDataSource _local;
  final _controller = StreamController<AuthSession?>.broadcast();
  final _rng = Random.secure();

  @override
  Stream<AuthSession?> get sessionChanges => _controller.stream;

  @override
  Future<AuthSession?> restoreSession() async {
    // Same contract as `BffAuthRepository.restoreSession` (audit-002
    // H-05): does NOT emit on the stream. The bloc decides.
    final session = await _local.read();
    if (session == null) return null;
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
    await _local.write(session);
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> refresh({CancelToken? cancel}) async {
    // Mock does not honor cancellation — the in-flight Future.delayed
    // is too short for cancellation to be a useful observable on dev
    // builds. Real cancellation lives in BffAuthRepository.
    final stored = await _local.read();
    if (stored == null) throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Carry forward the verification flags from the current session — a
    // refresh must not "un-verify" the user.
    final session = AuthSession.fromToken(
      accessToken: mockJwt(
        sub: 'mock-user-refreshed',
        emailVerified: stored.emailVerified,
        phoneNumber: stored.phoneNumber,
        phoneNumberVerified: stored.phoneNumberVerified,
      ),
      sessionId: stored.sessionId,
      expiresAt: DateTime.now().add(kMockSessionLifetime),
    );
    await _local.write(session);
    _controller.add(session);
    return session;
  }

  @override
  Future<void> logout({CancelToken? cancel}) async {
    await _local.clear();
    _controller.add(null);
  }

  @override
  Future<UserProfile> getProfile({CancelToken? cancel}) async {
    final session = await _local.read();
    if (session == null) throw AuthFailure(code: AuthErrorCode.notAuthenticated);
    return UserProfile(
      sub: 'mock-user-${_rng.nextInt(9999)}',
      username: 'mock.user',
      email: session.email ?? 'mock@example.test',
      emailVerified: session.emailVerified,
      phoneNumber: session.phoneNumber,
      phoneNumberVerified: session.phoneNumberVerified,
      roles: const ['citizen'],
      expiresAt: session.expiresAt,
    );
  }

  @override
  Future<void> replaceSession(AuthSession session) async {
    await _local.write(session);
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
