import 'package:dio/dio.dart';

import '../../auth/domain/auth_session.dart';

/// The verification feature's own repository.
///
/// Decoupled from [AuthRepository] (audit H-07): authentication does not
/// own OTP send/verify. The two interact only through
/// [AuthRepository.replaceSession] — when a verify call mints a fresh
/// internal JWT, the verification repo persists the new session via the
/// auth side so the auth stack remains the single source of truth for
/// "the current session".
///
/// Concrete impls:
///  - `BffVerificationRepository`  → real BFF endpoints (Fonnte for WA, SMTP for email).
///  - `MockVerificationRepository` → in-app dev fake that accepts `"123456"`.
abstract class VerificationRepository {
  /// Asks the BFF to send a 6-digit OTP to the user's verified-of-record
  /// email (`POST /auth/email/send-otp`). Returns the validity window so
  /// the UI can render a countdown.
  ///
  /// Pass [cancel] to abort the in-flight request — typically tied to
  /// the channel's CancelToken held by [VerificationBloc] (audit-002 H-02).
  Future<Duration> sendEmailOtp({CancelToken? cancel});

  /// Submits the user-entered code (`POST /auth/email/verify-otp`).
  /// On success: server mints a fresh internal JWT with
  /// `email_verified=true`; this method persists it via the auth side
  /// and returns the new session.
  Future<AuthSession> verifyEmailOtp(String code, {CancelToken? cancel});

  /// Asks the BFF to send a WA OTP via Fonnte (`POST /auth/phone/send-otp`).
  ///
  /// audit-003 M-03: no phone number is sent. The BFF resolves the
  /// citizen's number from their Keycloak profile (the IdP is the source
  /// of record, exactly as for email) and binds it to the OTP record
  /// server-side. The client never asserts a phone number — not on send,
  /// not on verify — which closes the cross-number vector entirely
  /// instead of relying on a BFF re-check.
  Future<Duration> sendPhoneOtp({CancelToken? cancel});

  /// Submits the user-entered code (`POST /auth/phone/verify-otp`).
  /// On success: same persistence contract as [verifyEmailOtp].
  ///
  /// audit-003 M-03: the phone number is intentionally NOT a parameter,
  /// symmetric with [sendPhoneOtp]. The BFF looks the bound number up
  /// from its own OTP record (itself seeded from the Keycloak profile).
  Future<AuthSession> verifyPhoneOtp(String code, {CancelToken? cancel});

  /// Releases owned resources (HTTP client, internal controllers).
  Future<void> dispose();
}
