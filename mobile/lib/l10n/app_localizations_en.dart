// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get authSessionExpired =>
      'Your session has expired. Please sign in again.';

  @override
  String get authLoginCancelled => 'Login was cancelled.';

  @override
  String get authLoginTimedOut => 'Login timed out. Please try again.';

  @override
  String get authLoginPlatformError => 'Login failed. Please try again.';

  @override
  String get authLoginMissingFields =>
      'The server did not return a complete login response.';

  @override
  String get authNotAuthenticated => 'You are not signed in.';

  @override
  String get authRefreshFailed => 'Could not refresh your session.';

  @override
  String get authNetwork =>
      'Could not connect. Check your internet connection.';

  @override
  String get authUnknown => 'An unexpected error occurred.';

  @override
  String get verifySendOtpFailed => 'Could not send the OTP code.';

  @override
  String get verifyVerifyOtpFailed => 'Verification failed.';

  @override
  String verifyOtpInvalidWithAttempts(int attempts) {
    return 'Wrong code. $attempts attempts left.';
  }

  @override
  String get verifyOtpInvalid => 'Wrong code.';

  @override
  String get verifyOtpExhausted =>
      'No attempts left. Please request a new code.';

  @override
  String get verifyOtpExpired =>
      'The code has expired. Please request a new one.';

  @override
  String get verifyNotAuthenticated => 'You are not signed in.';

  @override
  String get verifyPhoneNotEntered =>
      'Please enter your WhatsApp number first.';

  @override
  String get verifyNetwork =>
      'Could not connect. Check your internet connection.';

  @override
  String get verifyUnknown => 'An unexpected error occurred.';
}
