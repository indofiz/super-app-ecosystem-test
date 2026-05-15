import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/cancelled_exception.dart';
import '../../../auth/domain/auth_session.dart';
import '../../domain/verification_failure.dart';
import '../../domain/verification_repository.dart';

export '../../domain/verification_failure.dart' show VerificationErrorCode;

part 'verification_event.dart';
part 'verification_state.dart';

/// Read a channel slice from the current bloc state.
typedef _GetSlice = ChannelState Function();

/// Project a new channel slice into a full [VerificationState], leaving
/// the other channel untouched.
typedef _PutSlice = VerificationState Function(ChannelState);

/// One bloc, two channels (email + phone). Each channel has an
/// independent status, expiry clock, and last-error so the UI can keep
/// the two cards interactive in parallel.
///
/// The four event handlers (Email/Phone × Send/Verify) all share the
/// same state-machine shape — sending/verifying → success or coded
/// failure. The body lives in [_onSend] and [_onVerify]; the public
/// handlers only supply the channel-specific lambdas (which slice to
/// read/write, which repo method to call).
///
/// On a successful verify, the BFF (or mock) re-mints the session JWT
/// with the new claim flipped to true. `AuthRepository.sessionChanges`
/// broadcasts the new session; `AuthBloc` picks it up automatically, so
/// `VerificationBloc` does NOT need to wire back into auth state. The
/// banner reads the latest session via `BlocBuilder<AuthBloc, AuthState>`.
class VerificationBloc extends Bloc<VerificationEvent, VerificationState> {
  VerificationBloc({required this.verificationRepository})
      : super(const VerificationState()) {
    on<EmailSendOtpRequested>(_onSendEmail);
    on<EmailVerifyOtpRequested>(_onVerifyEmail);
    on<PhoneSendOtpRequested>(_onSendPhone);
    on<PhoneVerifyOtpRequested>(_onVerifyPhone);
    on<VerificationErrorCleared>(_onErrorCleared);
  }

  final VerificationRepository verificationRepository;

  /// Per-channel cancel tokens (audit-002 H-02). When the bloc is
  /// closed mid-flight, [close] cancels both — Dio aborts the in-flight
  /// request, the data layer translates that to a [CancelledException],
  /// and the handler's catch arm skips emission so we don't `emit` on a
  /// closed bloc.
  ///
  /// Per-channel granularity matters: the user can send email OTP and
  /// type a phone number in parallel; we don't want a cancellation on
  /// one channel to abort the other.
  final CancelToken _emailCancel = CancelToken();
  final CancelToken _phoneCancel = CancelToken();

  // -------- public event handlers (thin) --------

  Future<void> _onSendEmail(
    EmailSendOtpRequested event,
    Emitter<VerificationState> emit,
  ) =>
      _onSend(
        emit: emit,
        getSlice: () => state.email,
        putSlice: (s) => state.copyWith(email: s),
        send: () => verificationRepository.sendEmailOtp(cancel: _emailCancel),
      );

  Future<void> _onSendPhone(
    PhoneSendOtpRequested event,
    Emitter<VerificationState> emit,
  ) =>
      _onSend(
        emit: emit,
        getSlice: () => state.phone,
        putSlice: (s) => state.copyWith(phone: s),
        send: () => verificationRepository.sendPhoneOtp(
          event.phone,
          cancel: _phoneCancel,
        ),
        // The phone channel caches the number on the slice so a
        // subsequent verify call has it without a re-prompt.
        phoneToCache: event.phone,
      );

  Future<void> _onVerifyEmail(
    EmailVerifyOtpRequested event,
    Emitter<VerificationState> emit,
  ) =>
      _onVerify(
        emit: emit,
        getSlice: () => state.email,
        putSlice: (s) => state.copyWith(email: s),
        verify: () => verificationRepository.verifyEmailOtp(
          event.code,
          cancel: _emailCancel,
        ),
      );

  Future<void> _onVerifyPhone(
    PhoneVerifyOtpRequested event,
    Emitter<VerificationState> emit,
  ) async {
    // audit-002 H-07: verify against the phone the BFF has bound, not
    // the most-recent pending value. The two used to be the same field
    // (phoneNumber), so a future UI event mutating the pending phone
    // without a re-send would have made the bloc verify against a
    // number the BFF doesn't know.
    final phone = state.phone.verifyingPhone;
    if (phone == null) {
      // User tapped verify before any successful sendPhoneOtp —
      // UI-state guard, not a server failure. Doesn't reach the repo.
      emit(state.copyWith(
        phone: state.phone.copyWith(
          errorCode: () => VerificationErrorCode.phoneNotEntered,
        ),
      ));
      return;
    }
    return _onVerify(
      emit: emit,
      getSlice: () => state.phone,
      putSlice: (s) => state.copyWith(phone: s),
      verify: () => verificationRepository.verifyPhoneOtp(
        phone,
        event.code,
        cancel: _phoneCancel,
      ),
    );
  }

  void _onErrorCleared(
    VerificationErrorCleared event,
    Emitter<VerificationState> emit,
  ) {
    switch (event.channel) {
      case VerificationChannel.email:
        emit(state.copyWith(
          email: state.email.copyWith(errorCode: () => null),
        ));
      case VerificationChannel.phone:
        emit(state.copyWith(
          phone: state.phone.copyWith(errorCode: () => null),
        ));
    }
  }

  // -------- shared state machines --------

  /// `sending → awaitingCode` on success; `idle + errorCode` on failure.
  /// [phoneToCache], if supplied, is written to the slice's `phoneNumber`
  /// field on both the in-flight and post-success emits, and to
  /// [verifyingPhone] on the success emit only — see audit-002 H-07.
  /// The two-field split means a future UI mutation of the pending phone
  /// value (e.g. a hypothetical `PhoneNumberChanged` event) cannot
  /// diverge "what we verify against" from "what the BFF actually bound".
  Future<void> _onSend({
    required Emitter<VerificationState> emit,
    required _GetSlice getSlice,
    required _PutSlice putSlice,
    required Future<Duration> Function() send,
    String? phoneToCache,
  }) async {
    final cache = phoneToCache != null ? () => phoneToCache : null;
    emit(putSlice(getSlice().copyWith(
      status: ChannelStatus.sending,
      phoneNumber: cache,
      errorCode: () => null,
      attemptsLeft: () => null,
    )));
    try {
      final ttl = await send();
      emit(putSlice(getSlice().copyWith(
        status: ChannelStatus.awaitingCode,
        phoneNumber: cache,
        // Bind verifyingPhone only on a SUCCESSFUL send — if the BFF
        // rejected the send, there is no server-side OTP record yet.
        verifyingPhone: cache,
        expiresAt: () => DateTime.now().add(ttl),
      )));
    } on VerificationFailure catch (e) {
      emit(putSlice(getSlice().copyWith(
        status: ChannelStatus.idle,
        errorCode: () => e.code,
      )));
    } on CancelledException {
      // Caller (this bloc on close()) cancelled — skip emit. The bloc
      // is being disposed; the state machine is about to be discarded.
      return;
    }
  }

  /// `verifying → verified` on success; coded-failure transitions match
  /// [_statusForVerifyFailure]. Clears `expiresAt` only on `otpExpired`.
  Future<void> _onVerify({
    required Emitter<VerificationState> emit,
    required _GetSlice getSlice,
    required _PutSlice putSlice,
    required Future<AuthSession> Function() verify,
  }) async {
    emit(putSlice(getSlice().copyWith(
      status: ChannelStatus.verifying,
      errorCode: () => null,
      attemptsLeft: () => null,
    )));
    try {
      await verify();
      emit(putSlice(getSlice().copyWith(
        status: ChannelStatus.verified,
        errorCode: () => null,
        attemptsLeft: () => null,
        // BFF-side OTP record consumed — clear the binding so a future
        // verify can't reuse a phone the BFF no longer holds.
        verifyingPhone: () => null,
      )));
    } on VerificationFailure catch (e) {
      final nextStatus = _statusForVerifyFailure(e);
      emit(putSlice(getSlice().copyWith(
        status: nextStatus,
        // Only otpExpired clears the countdown; other failures leave the
        // existing TTL so the resend timer continues until expiry.
        expiresAt:
            e.code == VerificationErrorCode.otpExpired ? () => null : null,
        errorCode: () => e.code,
        attemptsLeft: () => e.attemptsLeft,
        // When the failure drops us out of awaitingCode/verifying, the
        // BFF-side record is gone (otpExpired, otpExhausted, transport
        // error → user must resend). Clear verifyingPhone so the next
        // send is required to re-bind. Retryable failures
        // (otpInvalid + attempts remaining) keep awaitingCode, so the
        // binding stays put.
        verifyingPhone:
            nextStatus == ChannelStatus.idle ? () => null : null,
      )));
    } on CancelledException {
      // Caller cancelled (bloc close) — skip emit.
      return;
    }
  }

  /// On a verify failure: stay on `awaitingCode` while there's any chance
  /// (otpInvalid + retryable). Anything else (expired, exhausted, transport
  /// error) drops to `idle` so the resend button becomes the only path.
  ChannelStatus _statusForVerifyFailure(VerificationFailure e) {
    if (e.code == VerificationErrorCode.otpInvalid &&
        (e.attemptsLeft ?? 0) > 0) {
      return ChannelStatus.awaitingCode;
    }
    return ChannelStatus.idle;
  }

  @override
  Future<void> close() async {
    // audit-002 H-02 scenario 1: cancel in-flight OTP send / verify
    // requests so they don't complete after the widget that mounted
    // this bloc has gone. Per-channel — both tokens get cancelled here
    // because we're about to discard the whole bloc.
    if (!_emailCancel.isCancelled) {
      _emailCancel.cancel('VerificationBloc.close');
    }
    if (!_phoneCancel.isCancelled) {
      _phoneCancel.cancel('VerificationBloc.close');
    }
    return super.close();
  }
}
