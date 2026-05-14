import 'auth_session.dart';

class AuthFailure implements Exception {
  AuthFailure(this.message, {this.cause, this.retryable = false});
  final String message;
  final Object? cause;
  final bool retryable;
  @override
  String toString() => 'AuthFailure: $message';
}

/// Thrown by the OTP-verify methods when the code did not match. The BFF
/// returns `attempts_left` in the body so the UI can show a "X tries
/// remaining" hint; the user has to start over once it hits zero.
class OtpInvalidFailure extends AuthFailure {
  OtpInvalidFailure({required this.attemptsLeft, Object? cause})
      : super(
          attemptsLeft > 0
              ? 'Kode salah. Sisa percobaan: $attemptsLeft.'
              : 'Kode salah.',
          cause: cause,
          retryable: attemptsLeft > 0,
        );
  final int attemptsLeft;
}

/// Thrown by the OTP-verify methods when no OTP record exists (expired
/// or already consumed). Caller should prompt user to resend.
class OtpExpiredFailure extends AuthFailure {
  OtpExpiredFailure({Object? cause})
      : super(
          'Kode kedaluwarsa. Silakan kirim ulang.',
          cause: cause,
          retryable: false,
        );
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

  /// Asks the BFF to send a 6-digit OTP code to the user's email
  /// (`POST /auth/email/send-otp`). Returns the validity window so the
  /// UI can render a countdown.
  Future<Duration> sendEmailOtp();

  /// Submits the user-entered code to the BFF
  /// (`POST /auth/email/verify-otp`). On success the BFF mints a fresh
  /// internal JWT with `email_verified=true`; the new session is stored,
  /// emitted on [sessionChanges], and returned.
  Future<AuthSession> verifyEmailOtp(String code);

  /// Asks the BFF to send a WA OTP via Fonnte
  /// (`POST /auth/phone/send-otp`). The [phone] number is bound to the
  /// outstanding OTP record server-side — the verify call must use the
  /// same number.
  Future<Duration> sendPhoneOtp(String phone);

  /// Submits the user-entered code (`POST /auth/phone/verify-otp`). On
  /// success the BFF writes `phoneNumberVerified=true` to KC, mints a
  /// new JWT, and returns it.
  Future<AuthSession> verifyPhoneOtp(String phone, String code);

  /// Broadcast stream of session changes (login / refresh / logout / verify).
  Stream<AuthSession?> get sessionChanges;
}
