/// Closed enumeration of auth-layer failures.
///
/// Lives in `domain/` so the data layer can produce it and the
/// presentation layer can map it to localized copy. The data and domain
/// layers MUST NOT format user-facing strings — they emit a code; the
/// presentation layer resolves it via [AppLocalizations].
enum AuthErrorCode {
  /// BFF says the server-side session is gone (Redis wiped, BFF
  /// restarted, or explicitly invalidated). Local credentials are now
  /// useless — the user must re-login.
  sessionExpired,

  /// User dismissed the Custom Tab / SFSafariViewController before the
  /// OAuth handshake completed. Retryable.
  loginCancelled,

  /// `flutter_appauth` never returned. Usually because Android killed
  /// the task while the Custom Tab was open. Retryable.
  loginTimedOut,

  /// `flutter_appauth` returned a platform-level exception (Chrome
  /// Custom Tabs missing, intent failure, scheme mismatch, etc.).
  loginPlatformError,

  /// BFF's `/auth/token` response was missing required fields
  /// (access_token / expires_in / session_id). Indicates a BFF-side bug.
  loginMissingFields,

  /// Operation required a session but none is in storage. Distinct from
  /// [sessionExpired] — the user never had a session, or already logged
  /// out locally.
  notAuthenticated,

  /// `/auth/refresh` failed with something other than 401 (e.g. 5xx,
  /// transport error). The local session is still valid.
  refreshFailed,

  /// Transport-level failure (connect/receive/send timeout). Retryable.
  network,

  /// Catch-all for everything we didn't recognise.
  unknown,
}

/// audit-004 M-02: derives retryability from the failure code rather than
/// duplicating it as a separate field on `AuthState` / `AuthFailure`.
/// Repository sites that set `AuthFailure.retryable` (e.g. timeouts at
/// `bff_auth_repository.dart:158,166`) become the legacy projection of
/// this; the UI consults `state.errorCode!.isRetryable` directly so the
/// two cannot drift apart.
extension AuthErrorCodeRetry on AuthErrorCode {
  /// True for failures another attempt of the same flow — without user
  /// re-input — might recover from. False for failures that require
  /// either re-authentication or out-of-band intervention.
  bool get isRetryable {
    switch (this) {
      case AuthErrorCode.loginCancelled:
      case AuthErrorCode.loginTimedOut:
      case AuthErrorCode.network:
        return true;
      case AuthErrorCode.sessionExpired:
      case AuthErrorCode.loginPlatformError:
      case AuthErrorCode.loginMissingFields:
      case AuthErrorCode.notAuthenticated:
      case AuthErrorCode.refreshFailed:
      case AuthErrorCode.unknown:
        return false;
    }
  }
}
