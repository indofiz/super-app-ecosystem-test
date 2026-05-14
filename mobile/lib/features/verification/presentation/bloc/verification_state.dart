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
    this.expiresAt,
    this.errorMessage,
  });

  final ChannelStatus status;

  /// Only used for the phone channel; null on the email channel.
  final String? phoneNumber;

  /// When the current OTP record expires (server clock + TTL). Drives
  /// the resend-timer countdown.
  final DateTime? expiresAt;

  final String? errorMessage;

  /// `copyWith` uses zero-arg-returning closures so callers can
  /// distinguish "leave alone" from "clear to null".
  ChannelState copyWith({
    ChannelStatus? status,
    String? Function()? phoneNumber,
    DateTime? Function()? expiresAt,
    String? Function()? errorMessage,
  }) {
    return ChannelState(
      status: status ?? this.status,
      phoneNumber: phoneNumber != null ? phoneNumber() : this.phoneNumber,
      expiresAt: expiresAt != null ? expiresAt() : this.expiresAt,
      errorMessage:
          errorMessage != null ? errorMessage() : this.errorMessage,
    );
  }

  bool get isBusy =>
      status == ChannelStatus.sending || status == ChannelStatus.verifying;

  @override
  List<Object?> get props => [status, phoneNumber, expiresAt, errorMessage];
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
