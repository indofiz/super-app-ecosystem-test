import '../../../l10n/app_localizations.dart';
import '../domain/auth_error_code.dart';

/// Resolves an [AuthErrorCode] to localized user-facing copy.
///
/// The data and domain layers never construct user-facing strings — they
/// emit codes. This is the one place that turns codes into text. If you
/// need a new auth error, add the enum value AND a matching ARB key.
String authErrorMessage(AppLocalizations l10n, AuthErrorCode code) {
  switch (code) {
    case AuthErrorCode.sessionExpired:
      return l10n.authSessionExpired;
    case AuthErrorCode.loginCancelled:
      return l10n.authLoginCancelled;
    case AuthErrorCode.loginTimedOut:
      return l10n.authLoginTimedOut;
    case AuthErrorCode.loginPlatformError:
      return l10n.authLoginPlatformError;
    case AuthErrorCode.loginMissingFields:
      return l10n.authLoginMissingFields;
    case AuthErrorCode.notAuthenticated:
      return l10n.authNotAuthenticated;
    case AuthErrorCode.refreshFailed:
      return l10n.authRefreshFailed;
    case AuthErrorCode.network:
      return l10n.authNetwork;
    case AuthErrorCode.unknown:
      return l10n.authUnknown;
  }
}
