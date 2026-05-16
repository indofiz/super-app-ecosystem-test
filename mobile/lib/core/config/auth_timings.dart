/// Single audit point for the auth/OTP timing contract with the BFF.
///
/// These describe the SAME physical system — tuning one without the others
/// creates skew (e.g. UI showing "Kirim ulang dalam 4:50" while the server
/// has already expired the code). Keeping them here means a reviewer can
/// audit the timing budget in one place; mocks read the same constants so
/// dev behavior matches prod.
library;

/// Hard cap on the flutter_appauth round-trip.
///
/// If Android kills the app's task while the Custom Tab is open, AppAuth's
/// `AuthorizationManagementActivity` loses its in-memory state and
/// `finish()`s without completing the Future. Without this timeout the
/// bloc would sit in `authenticating` forever.
const Duration kOauthLoginTimeout = Duration(minutes: 3);

/// Default OTP record TTL when the BFF response omits `expires_in`.
/// Matches the BFF's documented default for `/auth/{email,phone}/send-otp`.
const Duration kOtpDefaultTtl = Duration(seconds: 300);

/// How long a freshly-minted MOCK session lasts. Mirrors the BFF's
/// access-token TTL closely enough to exercise the refresh flow in dev.
const Duration kMockSessionLifetime = Duration(minutes: 5);

/// Minimum interval between OTP resend taps in the UI.
const Duration kOtpResendCooldown = Duration(seconds: 60);

/// Refresh-skew window applied to `AuthSession.isExpired` (audit-003
/// M-05). A session is treated as expired this far BEFORE its nominal
/// `expiresAt`, so the bloc proactively refreshes instead of firing a
/// request with a bearer that dies in transit. It also blunts the
/// device-clock-backdating bypass: trusting `DateTime.now()` alone let a
/// user hold the clock behind `expiresAt` and keep a stale session
/// "valid" in the UI between API calls — the skew shrinks that window
/// (the BFF/Kong server clock remains the real authority on `/api/*`).
const Duration kSessionExpirySkew = Duration(seconds: 30);
