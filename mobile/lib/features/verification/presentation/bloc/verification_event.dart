part of 'verification_bloc.dart';

enum VerificationChannel { email, phone }

sealed class VerificationEvent extends Equatable {
  const VerificationEvent();
  @override
  List<Object?> get props => const [];
}

class EmailSendOtpRequested extends VerificationEvent {
  const EmailSendOtpRequested();
}

class EmailVerifyOtpRequested extends VerificationEvent {
  const EmailVerifyOtpRequested(this.code);
  final String code;
  @override
  List<Object?> get props => [code];
}

/// audit-003 M-03: no payload. The BFF reads the citizen's number from
/// their Keycloak profile (source of record, same as email), so the
/// client never supplies one — there is no in-app phone-entry step.
class PhoneSendOtpRequested extends VerificationEvent {
  const PhoneSendOtpRequested();
}

class PhoneVerifyOtpRequested extends VerificationEvent {
  const PhoneVerifyOtpRequested(this.code);
  final String code;
  @override
  List<Object?> get props => [code];
}

class VerificationErrorCleared extends VerificationEvent {
  const VerificationErrorCleared(this.channel);
  final VerificationChannel channel;
  @override
  List<Object?> get props => [channel];
}
