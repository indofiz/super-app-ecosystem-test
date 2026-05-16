import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging/error_reporter.dart';
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
              // audit-003 L-04: *_this_device_only keeps the bearer and
              // session_id out of iCloud Keychain sync — a citizen-identity
              // credential must not replicate to the user's other devices.
              iOptions: IOSOptions(
                accessibility:
                    KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _kAccessToken = 'access_token';
  static const _kSessionId = 'session_id';
  static const _kExpiresAt = 'expires_at';

  /// Largest access token we will ever write to EncryptedSharedPreferences.
  /// A real BFF HS256 JWT tops out well under 2 KB; 16 KB gives generous
  /// headroom while blocking a misrouted multi-MB HTML payload that would
  /// brick the Android keystore (non-deterministic failure above ~1 MB).
  static const int _kMaxAccessTokenLength = 16 * 1024;

  final FlutterSecureStorage _storage;

  Future<void> writeSession(StoredSession session) async {
    final tokenLength = session.accessToken.length;
    if (tokenLength > _kMaxAccessTokenLength) {
      final err = StateError(
        'access_token too large to persist '
        '($tokenLength chars > $_kMaxAccessTokenLength limit)',
      );
      ErrorReporter.instance.reportError(
        err,
        StackTrace.current,
        context: 'SecureStore.writeSession',
        fatal: true,
      );
      throw err;
    }
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
