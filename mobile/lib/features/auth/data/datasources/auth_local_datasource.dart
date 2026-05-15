import '../../../../core/storage/secure_store.dart';
import '../../domain/auth_session.dart';

/// Local data source for the auth feature (audit-002 H-01).
///
/// Wraps [SecureStore] and translates between the on-disk [StoredSession]
/// record and the domain [AuthSession]. Repositories depend on this class
/// instead of `SecureStore` directly, so:
///
///   1. The on-disk record shape is invisible to repos (the storage record
///      only carries the three persistable fields; the rest of
///      [AuthSession] is JWT-derived). Future schema changes — adding a
///      `last_refresh` column, splitting the access_token off into its own
///      keychain entry — touch only this file.
///   2. Repo tests fake one class instead of three (this + remote +
///      AppAuth), so the repo's orchestration logic gets isolated.
///
/// Owns no resources; nothing to dispose.
class AuthLocalDataSource {
  AuthLocalDataSource({required this.secureStore});

  final SecureStore secureStore;

  /// Returns the persisted session, or `null` if storage is empty.
  Future<AuthSession?> read() async {
    final stored = await secureStore.readSession();
    if (stored == null) return null;
    return AuthSession.fromStored(stored);
  }

  /// Persists [session] (only the three storage fields are written; the
  /// derived JWT fields are re-decoded on the next [read]).
  Future<void> write(AuthSession session) async {
    await secureStore.writeSession(session.toStored());
  }

  /// Wipes the persisted session.
  Future<void> clear() async {
    await secureStore.clear();
  }
}
