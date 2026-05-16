import '../../../l10n/app_localizations.dart';
import '../domain/verification_failure.dart';

/// Resolves a [VerificationErrorCode] + optional [attemptsLeft] to
/// localized user-facing copy.
///
/// The two-argument form is necessary because `otpInvalid` needs to
/// include the attempts-left count — the rest of the codes only need the
/// code itself.
String verificationErrorMessage(
  AppLocalizations l10n,
  VerificationErrorCode code, {
  int? attemptsLeft,
}) {
  switch (code) {
    case VerificationErrorCode.sendOtpFailed:
      return l10n.verifySendOtpFailed;
    case VerificationErrorCode.verifyOtpFailed:
      return l10n.verifyVerifyOtpFailed;
    case VerificationErrorCode.otpInvalid:
      return attemptsLeft != null && attemptsLeft > 0
          ? l10n.verifyOtpInvalidWithAttempts(attemptsLeft)
          : l10n.verifyOtpInvalid;
    case VerificationErrorCode.otpExhausted:
      return l10n.verifyOtpExhausted;
    case VerificationErrorCode.otpExpired:
      return l10n.verifyOtpExpired;
    case VerificationErrorCode.notAuthenticated:
      return l10n.verifyNotAuthenticated;
    case VerificationErrorCode.network:
      return l10n.verifyNetwork;
    case VerificationErrorCode.unknown:
      return l10n.verifyUnknown;
  }
}
