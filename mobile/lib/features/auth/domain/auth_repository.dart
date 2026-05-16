import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';

import 'auth_error_code.dart';
import 'auth_session.dart';

/// Typed auth-layer failure.
///
/// The data layer throws this with an [AuthErrorCode]; the presentation
/// layer resolves the code into a localized string. [diagnostic] is the
/// raw server-side `error_description` / platform message — it goes to
/// logs only, never to user-facing UI.
///
/// Implements [Equatable] on [code], [diagnostic], and [retryable].
/// [cause] is excluded — it is an opaque debugging handle and cannot
/// be compared reliably by value.
class AuthFailure extends Equatable implements Exception {
  const AuthFailure({
    required this.code,
    this.diagnostic,
    this.cause,
    this.retryable = false,
  });

  final AuthErrorCode code;
  final String? diagnostic;
  final Object? cause;
  final bool retryable;

  @override
  List<Object?> get props => [code, diagnostic, retryable];

  @override
  String toString() =>
      'AuthFailure(code: $code${diagnostic != null ? ', diagnostic: $diagnostic' : ''})';
}

/// Profile snapshot returned by the BFF's `/auth/me` (or fabricated by the
/// mock repo). Matches the shape the BFF cached at login/refresh time.
class UserProfile {
  const UserProfile({
    required this.sub,
    this.username,
    this.email,
    this.emailVerified = false,
    this.phoneNumber,
    this.phoneNumberVerified = false,
    this.roles = const [],
    this.expiresAt,
  });

  final String sub;
  final String? username;
  final String? email;
  final bool emailVerified;
  final String? phoneNumber;
  final bool phoneNumberVerified;
  final List<String> roles;
  final DateTime? expiresAt;

  bool get fullyVerified => emailVerified && phoneNumberVerified;
}

abstract class AuthRepository {
  /// Restores an existing session from secure storage on app start.
  /// Returns null if no session exists.
  ///
  /// CONTRACT (audit-002 H-05): does **NOT** emit on [sessionChanges].
  /// Callers (the bloc) inspect the returned session and decide what to
  /// do next — emit `authenticated` directly for a fresh session, or
  /// trigger a silent [refresh] for an expired one. Emitting the
  /// restored session here would let the `ApiClient`'s token holder
  /// cache an expired bearer before the bloc could classify it.
  Future<AuthSession?> restoreSession();

  /// Triggers the BFF-mediated login flow via deeplink.
  /// The BFF wraps Keycloak; the app never talks to the IdP directly.
  ///
  /// Not cancellable — the flutter_appauth plugin owns the deeplink
  /// round-trip and does not surface a cancel handle (audit-002 H-02
  /// scenario 4 — documented upstream gap).
  Future<AuthSession> login();

  /// Asks the BFF to mint a new internal JWT using the opaque session_id.
  /// BFF holds the refresh_token in Redis (keyed by session_id) and rotates
  /// with Keycloak.
  ///
  /// Pass [cancel] to abort an in-flight refresh — typically when the
  /// caller's scope (a bloc / widget) is being disposed.
  Future<AuthSession> refresh({CancelToken? cancel});

  /// Tells the BFF to invalidate the Redis session and Keycloak session,
  /// then wipes local secure storage.
  ///
  /// Pass [cancel] to abort an in-flight logout. The local clear runs
  /// regardless (audit-002 H-06 — local state always reaches a clean
  /// `unauthenticated`).
  Future<void> logout({CancelToken? cancel});

  /// Fetches the current user profile from the BFF (`GET /auth/me`).
  /// Pass the current bearer (internal JWT) so the BFF can authenticate the call.
  Future<UserProfile> getProfile({CancelToken? cancel});

  /// Re-confirms the restored session's identity flags against the BFF's
  /// canonical `/auth/me` (audit-003 C-05).
  ///
  /// `restoreSession()` returns a session whose `email_verified` /
  /// `phone_number_verified` flags were decoded from the on-device JWT —
  /// a token whose signature this app never verifies. A rooted attacker
  /// can rewrite the stored blob to fake "verified" UI gates. Callers
  /// (the bloc, on cold start) invoke this right after lifting a fresh
  /// restored session so the JWT-decoded flags are replaced by
  /// BFF-confirmed values; the corrected session is broadcast on
  /// [sessionChanges]. Best-effort: on any failure the restored session
  /// is left as a degraded fallback (no throw).
  Future<void> confirmIdentity();

  /// Persists [session] and broadcasts it on [sessionChanges]. Used by
  /// out-of-band flows (e.g. `VerificationRepository.verifyEmailOtp`) that
  /// re-mint the session against a different endpoint but still need the
  /// auth stack to be the single source of truth for "the current session".
  Future<void> replaceSession(AuthSession session);

  /// Broadcast stream of session changes (login / refresh / logout /
  /// verify). All session mutations — including [replaceSession] — emit here.
  Stream<AuthSession?> get sessionChanges;

  /// Releases owned resources — closes the [sessionChanges] controller and
  /// any underlying HTTP clients the repository constructed itself.
  /// Callers must dispose subscribers (e.g. AuthBloc, ApiClient) BEFORE
  /// calling this so they don't observe a `Bad state: Stream has already
  /// been listened to` from the closed controller.
  Future<void> dispose();
}
