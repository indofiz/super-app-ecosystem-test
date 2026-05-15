part of 'verification_bloc.dart';

enum ChannelStatus {
  /// Initial state, or after a resend rate-limit error.
  idle,

  /// `send-otp` in flight.
  sending,

  /// OTP delivered; UI shows the 6-digit input.
  awaitingCode,

  /// `verify-otp` in flight.
  verifying,

  /// Verify succeeded. Auth bloc will pick up the new session.
  verified,
}

class ChannelState extends Equatable {
  const ChannelState({
    this.status = ChannelStatus.idle,
    this.phoneNumber,
    this.verifyingPhone,
    this.expiresAt,
    this.errorCode,
    this.attemptsLeft,
  });

  final ChannelStatus status;

  /// Phone the bloc has cached from the most-recent send-OTP event.
  /// Used by the UI for display (the "Kami telah mengirim kode ke X"
  /// label on the code-input step). Only the phone channel uses this;
  /// null on the email channel.
  final String? phoneNumber;

  /// Phone bound to the current server-side OTP record (audit-002
  /// H-07). Set to the value passed to `sendPhoneOtp` on a successful
  /// send; cleared when the OTP record is gone (verify success, expiry,
  /// or attempts exhausted). The bloc's verify call passes THIS to the
  /// repo — distinct from [phoneNumber] so a future UI mutation of the
  /// pending value cannot diverge what we verify against from what the
  /// BFF expects.
  ///
  /// Always null on the email channel.
  final String? verifyingPhone;

  /// When the current OTP record expires (server clock + TTL). Drives
  /// the resend-timer countdown.
  final DateTime? expiresAt;

  /// Typed error from the last verification action, or null if none.
  /// Presentation layer maps this to a localized string.
  final VerificationErrorCode? errorCode;

  /// Server-reported attempts remaining for [VerificationErrorCode.otpInvalid].
  /// Null when [errorCode] doesn't carry attempts.
  final int? attemptsLeft;

  /// `copyWith` uses zero-arg-returning closures so callers can
  /// distinguish "leave alone" from "clear to null".
  ChannelState copyWith({
    ChannelStatus? status,
    String? Function()? phoneNumber,
    String? Function()? verifyingPhone,
    DateTime? Function()? expiresAt,
    VerificationErrorCode? Function()? errorCode,
    int? Function()? attemptsLeft,
  }) {
    return ChannelState(
      status: status ?? this.status,
      phoneNumber: phoneNumber != null ? phoneNumber() : this.phoneNumber,
      verifyingPhone:
          verifyingPhone != null ? verifyingPhone() : this.verifyingPhone,
      expiresAt: expiresAt != null ? expiresAt() : this.expiresAt,
      errorCode: errorCode != null ? errorCode() : this.errorCode,
      attemptsLeft:
          attemptsLeft != null ? attemptsLeft() : this.attemptsLeft,
    );
  }

  bool get isBusy =>
      status == ChannelStatus.sending || status == ChannelStatus.verifying;

  @override
  List<Object?> get props => [
        status,
        phoneNumber,
        verifyingPhone,
        expiresAt,
        errorCode,
        attemptsLeft,
      ];
}

class VerificationState extends Equatable {
  const VerificationState({
    this.email = const ChannelState(),
    this.phone = const ChannelState(),
  });

  final ChannelState email;
  final ChannelState phone;

  VerificationState copyWith({ChannelState? email, ChannelState? phone}) {
    return VerificationState(
      email: email ?? this.email,
      phone: phone ?? this.phone,
    );
  }

  @override
  List<Object?> get props => [email, phone];
}
