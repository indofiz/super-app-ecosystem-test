import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'stored_session.dart';

/// Encrypted at-rest storage for the two things mobile is allowed to hold:
/// the BFF-minted internal JWT (short-lived bearer) and the opaque
/// session_id that the BFF uses to look up the Keycloak refresh_token in
/// Redis. The refresh_token itself never reaches the device.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  static const _kAccessToken = 'access_token';
  static const _kSessionId = 'session_id';
  static const _kExpiresAt = 'expires_at';

  final FlutterSecureStorage _storage;

  Future<void> writeSession(StoredSession session) async {
    await Future.wait([
      _storage.write(key: _kAccessToken, value: session.accessToken),
      _storage.write(key: _kSessionId, value: session.sessionId),
      _storage.write(
        key: _kExpiresAt,
        value: session.expiresAt.toUtc().toIso8601String(),
      ),
    ]);
  }

  Future<StoredSession?> readSession() async {
    final accessToken = await _storage.read(key: _kAccessToken);
    final sessionId = await _storage.read(key: _kSessionId);
    final expiresAtRaw = await _storage.read(key: _kExpiresAt);
    if (accessToken == null || sessionId == null || expiresAtRaw == null) {
      return null;
    }
    return StoredSession(
      accessToken: accessToken,
      sessionId: sessionId,
      expiresAt: DateTime.parse(expiresAtRaw),
    );
  }

  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _kAccessToken),
      _storage.delete(key: _kSessionId),
      _storage.delete(key: _kExpiresAt),
    ]);
  }
}
