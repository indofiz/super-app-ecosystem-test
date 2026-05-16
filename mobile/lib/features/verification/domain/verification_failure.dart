import 'package:equatable/equatable.dart';

/// Closed enumeration of verification-layer failures.
///
/// Same contract as `AuthErrorCode`: data layer emits the code, presentation
/// layer resolves it via [AppLocalizations]. No user copy lives below
/// `presentation/`.
enum VerificationErrorCode {
  /// Send-OTP failed for reasons other than transport (BFF returned an
  /// error body, SMTP/Fonnte upstream rejected, etc.).
  sendOtpFailed,

  /// Verify-OTP failed for reasons other than the typed below cases
  /// (e.g. BFF 5xx, malformed response).
  verifyOtpFailed,

  /// User typed the wrong code; server says there are still attempts left.
  /// Carries [VerificationFailure.attemptsLeft] > 0.
  otpInvalid,

  /// User has exhausted their attempts on the current OTP record. Must
  /// re-request a new OTP. Carries `attemptsLeft == 0`.
  otpExhausted,

  /// OTP record has expired or was already consumed (BFF 410).
  otpExpired,

  /// No session in storage. The verify/send call cannot identify the
  /// user; bounce back to login.
  notAuthenticated,

  /// Transport-level failure.
  network,

  /// Catch-all.
  unknown,
}

/// [cause] is excluded from equality — it is an opaque debugging handle.
class VerificationFailure extends Equatable implements Exception {
  const VerificationFailure({
    required this.code,
    this.attemptsLeft,
    this.diagnostic,
    this.cause,
    this.retryable = false,
  });

  final VerificationErrorCode code;

  /// Server-reported remaining attempts on the current OTP record. Only
  /// meaningful for [VerificationErrorCode.otpInvalid] /
  /// [VerificationErrorCode.otpExhausted].
  final int? attemptsLeft;

  final String? diagnostic;
  final Object? cause;
  final bool retryable;

  @override
  List<Object?> get props => [code, attemptsLeft, diagnostic, retryable];

  @override
  String toString() =>
      'VerificationFailure(code: $code${attemptsLeft != null ? ', attemptsLeft: $attemptsLeft' : ''}${diagnostic != null ? ', diagnostic: $diagnostic' : ''})';
}
