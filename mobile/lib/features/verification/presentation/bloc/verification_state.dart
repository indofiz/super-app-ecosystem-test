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
    this.expiresAt,
    this.errorCode,
    this.attemptsLeft,
  });

  final ChannelStatus status;

  /// When the current OTP record expires (server clock + TTL). Drives
  /// the resend-timer countdown.
  ///
  /// audit-003 M-03: there is no per-channel phone/email field. Neither
  /// identifier ever lives in bloc state — the BFF resolves the
  /// destination from the Keycloak profile, and the UI shows it by
  /// reading the auth session (`AuthBloc`), the single source of record.
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
    DateTime? Function()? expiresAt,
    VerificationErrorCode? Function()? errorCode,
    int? Function()? attemptsLeft,
  }) {
    return ChannelState(
      status: status ?? this.status,
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
