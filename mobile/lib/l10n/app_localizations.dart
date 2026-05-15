import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_id.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('id'),
  ];

  /// AuthErrorCode.sessionExpired
  ///
  /// In id, this message translates to:
  /// **'Sesi berakhir. Silakan masuk kembali.'**
  String get authSessionExpired;

  /// AuthErrorCode.loginCancelled
  ///
  /// In id, this message translates to:
  /// **'Login dibatalkan.'**
  String get authLoginCancelled;

  /// AuthErrorCode.loginTimedOut
  ///
  /// In id, this message translates to:
  /// **'Waktu login habis. Silakan coba lagi.'**
  String get authLoginTimedOut;

  /// AuthErrorCode.loginPlatformError
  ///
  /// In id, this message translates to:
  /// **'Login gagal. Silakan coba lagi.'**
  String get authLoginPlatformError;

  /// AuthErrorCode.loginMissingFields
  ///
  /// In id, this message translates to:
  /// **'Server tidak mengirim data login yang lengkap.'**
  String get authLoginMissingFields;

  /// AuthErrorCode.notAuthenticated
  ///
  /// In id, this message translates to:
  /// **'Anda belum masuk.'**
  String get authNotAuthenticated;

  /// AuthErrorCode.refreshFailed
  ///
  /// In id, this message translates to:
  /// **'Gagal memperbarui sesi.'**
  String get authRefreshFailed;

  /// AuthErrorCode.network
  ///
  /// In id, this message translates to:
  /// **'Tidak dapat terhubung. Periksa koneksi internet Anda.'**
  String get authNetwork;

  /// AuthErrorCode.unknown
  ///
  /// In id, this message translates to:
  /// **'Terjadi kesalahan tak terduga.'**
  String get authUnknown;

  /// VerificationErrorCode.sendOtpFailed
  ///
  /// In id, this message translates to:
  /// **'Gagal mengirim kode OTP.'**
  String get verifySendOtpFailed;

  /// VerificationErrorCode.verifyOtpFailed
  ///
  /// In id, this message translates to:
  /// **'Verifikasi gagal.'**
  String get verifyVerifyOtpFailed;

  /// Wrong OTP, still has attempts left
  ///
  /// In id, this message translates to:
  /// **'Kode salah. Sisa percobaan: {attempts}.'**
  String verifyOtpInvalidWithAttempts(int attempts);

  /// Wrong OTP, attemptsLeft unknown
  ///
  /// In id, this message translates to:
  /// **'Kode salah.'**
  String get verifyOtpInvalid;

  /// VerificationErrorCode.otpExhausted
  ///
  /// In id, this message translates to:
  /// **'Percobaan habis. Silakan kirim ulang kode.'**
  String get verifyOtpExhausted;

  /// VerificationErrorCode.otpExpired
  ///
  /// In id, this message translates to:
  /// **'Kode kedaluwarsa. Silakan kirim ulang.'**
  String get verifyOtpExpired;

  /// VerificationErrorCode.notAuthenticated
  ///
  /// In id, this message translates to:
  /// **'Anda belum masuk.'**
  String get verifyNotAuthenticated;

  /// VerificationErrorCode.phoneNotEntered
  ///
  /// In id, this message translates to:
  /// **'Nomor WhatsApp belum dimasukkan.'**
  String get verifyPhoneNotEntered;

  /// VerificationErrorCode.network
  ///
  /// In id, this message translates to:
  /// **'Tidak dapat terhubung. Periksa koneksi internet Anda.'**
  String get verifyNetwork;

  /// VerificationErrorCode.unknown
  ///
  /// In id, this message translates to:
  /// **'Terjadi kesalahan tak terduga.'**
  String get verifyUnknown;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'id'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'id':
      return AppLocalizationsId();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
