/// The raw three-field session shape that lives in secure storage.
///
/// This is `(accessToken, sessionId, expiresAt)` — exactly the fields
/// SecureStore persists. It is INTENTIONALLY thinner than `AuthSession`:
/// `AuthSession` adds JWT-decoded fields (email, verified flags, etc.)
/// which are derived from `accessToken` and not stored separately.
///
/// Layering: this class lives in `core/storage/` and knows nothing about
/// JWT semantics. `AuthSession.fromStored(...)` decodes the JWT to fill
/// in the typed fields; that conversion stays on the domain side.
class StoredSession {
  const StoredSession({
    required this.accessToken,
    required this.sessionId,
    required this.expiresAt,
  });

  final String accessToken;
  final String sessionId;
  final DateTime expiresAt;
}
