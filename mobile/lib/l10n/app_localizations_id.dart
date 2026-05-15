// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get authSessionExpired => 'Sesi berakhir. Silakan masuk kembali.';

  @override
  String get authLoginCancelled => 'Login dibatalkan.';

  @override
  String get authLoginTimedOut => 'Waktu login habis. Silakan coba lagi.';

  @override
  String get authLoginPlatformError => 'Login gagal. Silakan coba lagi.';

  @override
  String get authLoginMissingFields =>
      'Server tidak mengirim data login yang lengkap.';

  @override
  String get authNotAuthenticated => 'Anda belum masuk.';

  @override
  String get authRefreshFailed => 'Gagal memperbarui sesi.';

  @override
  String get authNetwork =>
      'Tidak dapat terhubung. Periksa koneksi internet Anda.';

  @override
  String get authUnknown => 'Terjadi kesalahan tak terduga.';

  @override
  String get verifySendOtpFailed => 'Gagal mengirim kode OTP.';

  @override
  String get verifyVerifyOtpFailed => 'Verifikasi gagal.';

  @override
  String verifyOtpInvalidWithAttempts(int attempts) {
    return 'Kode salah. Sisa percobaan: $attempts.';
  }

  @override
  String get verifyOtpInvalid => 'Kode salah.';

  @override
  String get verifyOtpExhausted => 'Percobaan habis. Silakan kirim ulang kode.';

  @override
  String get verifyOtpExpired => 'Kode kedaluwarsa. Silakan kirim ulang.';

  @override
  String get verifyNotAuthenticated => 'Anda belum masuk.';

  @override
  String get verifyPhoneNotEntered => 'Nomor WhatsApp belum dimasukkan.';

  @override
  String get verifyNetwork =>
      'Tidak dapat terhubung. Periksa koneksi internet Anda.';

  @override
  String get verifyUnknown => 'Terjadi kesalahan tak terduga.';
}
