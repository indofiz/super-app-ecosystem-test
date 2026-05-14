import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/domain/auth_repository.dart';

part 'verification_event.dart';
part 'verification_state.dart';

/// One bloc, two channels (email + phone). Each channel has an
/// independent status, expiry clock, and last-error so the UI can keep
/// the two cards interactive in parallel.
///
/// On a successful verify, the BFF (or mock) re-mints the session JWT
/// with the new claim flipped to true. `AuthRepository.sessionChanges`
/// broadcasts the new session; `AuthBloc` picks it up automatically, so
/// `VerificationBloc` does NOT need to wire back into auth state. The
/// banner reads the latest session via `BlocBuilder<AuthBloc, AuthState>`.
class VerificationBloc extends Bloc<VerificationEvent, VerificationState> {
  VerificationBloc({required this.authRepository})
      : super(const VerificationState()) {
    on<EmailSendOtpRequested>(_onSendEmail);
    on<EmailVerifyOtpRequested>(_onVerifyEmail);
    on<PhoneSendOtpRequested>(_onSendPhone);
    on<PhoneVerifyOtpRequested>(_onVerifyPhone);
    on<VerificationErrorCleared>(_onErrorCleared);
  }

  final AuthRepository authRepository;

  Future<void> _onSendEmail(
    EmailSendOtpRequested event,
    Emitter<VerificationState> emit,
  ) async {
    emit(state.copyWith(
      email: state.email.copyWith(
        status: ChannelStatus.sending,
        errorMessage: () => null,
      ),
    ));
    try {
      final ttl = await authRepository.sendEmailOtp();
      emit(state.copyWith(
        email: state.email.copyWith(
          status: ChannelStatus.awaitingCode,
          expiresAt: () => DateTime.now().add(ttl),
        ),
      ));
    } on AuthFailure catch (e) {
      emit(state.copyWith(
        email: state.email.copyWith(
          status: ChannelStatus.idle,
          errorMessage: () => e.message,
        ),
      ));
    }
  }

  Future<void> _onVerifyEmail(
    EmailVerifyOtpRequested event,
    Emitter<VerificationState> emit,
  ) async {
    emit(state.copyWith(
      email: state.email.copyWith(
        status: ChannelStatus.verifying,
        errorMessage: () => null,
      ),
    ));
    try {
      await authRepository.verifyEmailOtp(event.code);
      emit(state.copyWith(
        email: state.email.copyWith(
          status: ChannelStatus.verified,
          errorMessage: () => null,
        ),
      ));
    } on OtpInvalidFailure catch (e) {
      emit(state.copyWith(
        email: state.email.copyWith(
          status: e.attemptsLeft > 0
              ? ChannelStatus.awaitingCode
              : ChannelStatus.idle,
          errorMessage: () => e.message,
        ),
      ));
    } on OtpExpiredFailure catch (e) {
      emit(state.copyWith(
        email: state.email.copyWith(
          status: ChannelStatus.idle,
          expiresAt: () => null,
          errorMessage: () => e.message,
        ),
      ));
    } on AuthFailure catch (e) {
      emit(state.copyWith(
        email: state.email.copyWith(
          status: ChannelStatus.awaitingCode,
          errorMessage: () => e.message,
        ),
      ));
    }
  }

  Future<void> _onSendPhone(
    PhoneSendOtpRequested event,
    Emitter<VerificationState> emit,
  ) async {
    emit(state.copyWith(
      phone: state.phone.copyWith(
        status: ChannelStatus.sending,
        phoneNumber: () => event.phone,
        errorMessage: () => null,
      ),
    ));
    try {
      final ttl = await authRepository.sendPhoneOtp(event.phone);
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: ChannelStatus.awaitingCode,
          phoneNumber: () => event.phone,
          expiresAt: () => DateTime.now().add(ttl),
        ),
      ));
    } on AuthFailure catch (e) {
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: ChannelStatus.idle,
          errorMessage: () => e.message,
        ),
      ));
    }
  }

  Future<void> _onVerifyPhone(
    PhoneVerifyOtpRequested event,
    Emitter<VerificationState> emit,
  ) async {
    final phone = state.phone.phoneNumber;
    if (phone == null) {
      emit(state.copyWith(
        phone: state.phone.copyWith(
          errorMessage: () => 'Nomor WhatsApp belum dimasukkan.',
        ),
      ));
      return;
    }
    emit(state.copyWith(
      phone: state.phone.copyWith(
        status: ChannelStatus.verifying,
        errorMessage: () => null,
      ),
    ));
    try {
      await authRepository.verifyPhoneOtp(phone, event.code);
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: ChannelStatus.verified,
          errorMessage: () => null,
        ),
      ));
    } on OtpInvalidFailure catch (e) {
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: e.attemptsLeft > 0
              ? ChannelStatus.awaitingCode
              : ChannelStatus.idle,
          errorMessage: () => e.message,
        ),
      ));
    } on OtpExpiredFailure catch (e) {
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: ChannelStatus.idle,
          expiresAt: () => null,
          errorMessage: () => e.message,
        ),
      ));
    } on AuthFailure catch (e) {
      emit(state.copyWith(
        phone: state.phone.copyWith(
          status: ChannelStatus.awaitingCode,
          errorMessage: () => e.message,
        ),
      ));
    }
  }

  void _onErrorCleared(
    VerificationErrorCleared event,
    Emitter<VerificationState> emit,
  ) {
    switch (event.channel) {
      case VerificationChannel.email:
        emit(state.copyWith(
          email: state.email.copyWith(errorMessage: () => null),
        ));
      case VerificationChannel.phone:
        emit(state.copyWith(
          phone: state.phone.copyWith(errorMessage: () => null),
        ));
    }
  }
}
