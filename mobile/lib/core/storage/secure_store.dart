import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  static const _kAccessToken = 'access_token';
  static const _kSessionId = 'session_id';
  static const _kExpiresAt = 'expires_at';
  static const _kIdToken = 'id_token';

  final FlutterSecureStorage _storage;

  Future<void> writeSession({
    required String accessToken,
    required String sessionId,
    required DateTime expiresAt,
    String? idToken,
  }) async {
    await Future.wait([
      _storage.write(key: _kAccessToken, value: accessToken),
      _storage.write(key: _kSessionId, value: sessionId),
      _storage.write(
          key: _kExpiresAt, value: expiresAt.toUtc().toIso8601String()),
      if (idToken != null) _storage.write(key: _kIdToken, value: idToken),
    ]);
  }

  Future<({String accessToken, String sessionId, DateTime expiresAt, String? idToken})?>
      readSession() async {
    final accessToken = await _storage.read(key: _kAccessToken);
    final sessionId = await _storage.read(key: _kSessionId);
    final expiresAtRaw = await _storage.read(key: _kExpiresAt);
    if (accessToken == null || sessionId == null || expiresAtRaw == null) {
      return null;
    }
    return (
      accessToken: accessToken,
      sessionId: sessionId,
      expiresAt: DateTime.parse(expiresAtRaw),
      idToken: await _storage.read(key: _kIdToken),
    );
  }

  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _kAccessToken),
      _storage.delete(key: _kSessionId),
      _storage.delete(key: _kExpiresAt),
      _storage.delete(key: _kIdToken),
    ]);
  }
}
