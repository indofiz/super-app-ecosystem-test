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
///
/// Swap to BffAuthRepository by flipping USE_MOCK_AUTH=false in .env.
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
    final session = AuthSession(
      accessToken: stored.accessToken,
      sessionId: stored.sessionId,
      expiresAt: stored.expiresAt,
      idToken: stored.idToken,
    );
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> login() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final session = AuthSession(
      accessToken: _fakeJwt(sub: 'mock-user-${_rng.nextInt(9999)}'),
      sessionId: _randomToken(32),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      idToken: _fakeJwt(sub: 'mock-user'),
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
      idToken: session.idToken,
    );
    _controller.add(session);
    return session;
  }

  @override
  Future<AuthSession> refresh() async {
    final stored = await secureStore.readSession();
    if (stored == null) throw AuthFailure('No session to refresh.');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final session = AuthSession(
      accessToken: _fakeJwt(sub: 'mock-user-refreshed'),
      sessionId: stored.sessionId,
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      idToken: stored.idToken,
    );
    await secureStore.writeSession(
      accessToken: session.accessToken,
      sessionId: session.sessionId,
      expiresAt: session.expiresAt,
      idToken: session.idToken,
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
      roles: const ['citizen'],
      expiresAt: stored.expiresAt,
    );
  }

  String _randomToken(int bytes) {
    final values = List<int>.generate(bytes, (_) => _rng.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  String _fakeJwt({required String sub}) {
    String b64(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final header = b64({'alg': 'none', 'typ': 'JWT'});
    final payload = b64({
      'iss': 'mock-bff',
      'sub': sub,
      'name': 'Mock User',
      'preferred_username': sub,
      'realm': 'pangkalpinang',
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
    });
    return '$header.$payload.';
  }
}
