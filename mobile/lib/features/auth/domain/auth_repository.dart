import 'auth_session.dart';

class AuthFailure implements Exception {
  AuthFailure(this.message, {this.cause, this.retryable = false});
  final String message;
  final Object? cause;
  final bool retryable;
  @override
  String toString() => 'AuthFailure: $message';
}

/// Profile snapshot returned by the BFF's `/auth/me` (or fabricated by the
/// mock repo). Matches the shape the BFF cached at login/refresh time.
class UserProfile {
  const UserProfile({
    required this.sub,
    this.username,
    this.email,
    this.roles = const [],
    this.expiresAt,
  });

  final String sub;
  final String? username;
  final String? email;
  final List<String> roles;
  final DateTime? expiresAt;
}

abstract class AuthRepository {
  /// Restores an existing session from secure storage on app start.
  /// Returns null if no session exists.
  Future<AuthSession?> restoreSession();

  /// Triggers the BFF-mediated login flow via deeplink.
  /// The BFF wraps Keycloak; the app never talks to the IdP directly.
  Future<AuthSession> login();

  /// Asks the BFF to mint a new internal JWT using the opaque session_id.
  /// BFF holds the refresh_token in Redis (keyed by session_id) and rotates
  /// with Keycloak.
  Future<AuthSession> refresh();

  /// Tells the BFF to invalidate the Redis session and Keycloak session,
  /// then wipes local secure storage.
  Future<void> logout();

  /// Fetches the current user profile from the BFF (`GET /auth/me`).
  /// Pass the current bearer (internal JWT) so the BFF can authenticate the call.
  Future<UserProfile> getProfile();

  /// Broadcast stream of session changes (login / refresh / logout).
  Stream<AuthSession?> get sessionChanges;
}
