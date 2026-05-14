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

class PhoneSendOtpRequested extends VerificationEvent {
  const PhoneSendOtpRequested(this.phone);
  final String phone;
  @override
  List<Object?> get props => [phone];
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
