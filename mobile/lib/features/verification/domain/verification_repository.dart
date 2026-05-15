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
  Future<Duration> sendEmailOtp();

  /// Submits the user-entered code (`POST /auth/email/verify-otp`).
  /// On success: server mints a fresh internal JWT with
  /// `email_verified=true`; this method persists it via the auth side
  /// and returns the new session.
  Future<AuthSession> verifyEmailOtp(String code);

  /// Asks the BFF to send a WA OTP via Fonnte (`POST /auth/phone/send-otp`).
  /// The [phone] number is bound to the outstanding OTP record server-side
  /// — [verifyPhoneOtp] must use the same number.
  Future<Duration> sendPhoneOtp(String phone);

  /// Submits the user-entered code (`POST /auth/phone/verify-otp`).
  /// On success: same persistence contract as [verifyEmailOtp].
  Future<AuthSession> verifyPhoneOtp(String phone, String code);

  /// Releases owned resources (HTTP client, internal controllers).
  Future<void> dispose();
}
