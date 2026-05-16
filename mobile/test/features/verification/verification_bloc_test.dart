import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/core/network/cancelled_exception.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/verification/domain/verification_failure.dart';
import 'package:smart_app_test/features/verification/domain/verification_repository.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';

class _MockVerificationRepository extends Mock
    implements VerificationRepository {}

class _FakeCancelToken extends Fake implements CancelToken {}

AuthSession _session() => AuthSession(
      accessToken: 'jwt',
      sessionId: 'sid-1',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      emailVerified: false,
      phoneNumberVerified: false,
    );

void main() {
  setUpAll(() {
    // Needed so `any(named: 'cancel')` can match a CancelToken named arg.
    registerFallbackValue(_FakeCancelToken());
  });

  late _MockVerificationRepository repo;

  setUp(() {
    repo = _MockVerificationRepository();
  });

  group('email channel', () {
    blocTest<VerificationBloc, VerificationState>(
      'sending → awaitingCode on successful send',
      build: () {
        when(() => repo.sendEmailOtp(cancel: any(named: 'cancel')))
            .thenAnswer((_) async => const Duration(seconds: 300));
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailSendOtpRequested()),
      expect: () => [
        isA<VerificationState>().having(
          (s) => s.email.status,
          'email.status',
          ChannelStatus.sending,
        ),
        isA<VerificationState>()
            .having(
              (s) => s.email.status,
              'email.status',
              ChannelStatus.awaitingCode,
            )
            .having(
              (s) => s.email.expiresAt,
              'email.expiresAt',
              isNotNull,
            ),
      ],
    );

    blocTest<VerificationBloc, VerificationState>(
      'send failure → idle with sendOtpFailed code',
      build: () {
        when(() => repo.sendEmailOtp(cancel: any(named: 'cancel'))).thenThrow(
          VerificationFailure(code: VerificationErrorCode.sendOtpFailed),
        );
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailSendOtpRequested()),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.errorCode, VerificationErrorCode.sendOtpFailed);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify happy path → verified',
      build: () {
        when(() =>
                repo.verifyEmailOtp(any(), cancel: any(named: 'cancel')))
            .thenAnswer((_) async => _session());
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('123456')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.verified);
        expect(bloc.state.email.errorCode, isNull);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'otpInvalid with attemptsLeft>0 → awaitingCode + code + attemptsLeft',
      build: () {
        when(() => repo.verifyEmailOtp(any(), cancel: any(named: 'cancel')))
            .thenThrow(
          VerificationFailure(
            code: VerificationErrorCode.otpInvalid,
            attemptsLeft: 3,
            retryable: true,
          ),
        );
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.awaitingCode);
        expect(bloc.state.email.errorCode, VerificationErrorCode.otpInvalid);
        expect(bloc.state.email.attemptsLeft, 3);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'otpExhausted (attemptsLeft=0) → idle (forces resend)',
      build: () {
        when(() => repo.verifyEmailOtp(any(), cancel: any(named: 'cancel')))
            .thenThrow(
          VerificationFailure(
            code: VerificationErrorCode.otpExhausted,
            attemptsLeft: 0,
          ),
        );
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.errorCode, VerificationErrorCode.otpExhausted);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'otpExpired → idle, expiresAt cleared',
      build: () {
        when(() => repo.verifyEmailOtp(any(), cancel: any(named: 'cancel')))
            .thenThrow(
          VerificationFailure(code: VerificationErrorCode.otpExpired),
        );
        return VerificationBloc(verificationRepository: repo);
      },
      seed: () => const VerificationState(
        email: ChannelState(status: ChannelStatus.awaitingCode),
      ),
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.expiresAt, isNull);
        expect(bloc.state.email.errorCode, VerificationErrorCode.otpExpired);
      },
    );
  });

  group('phone channel (mirrors email — audit-003 M-03)', () {
    blocTest<VerificationBloc, VerificationState>(
      'send: sending → awaitingCode (no phone on the wire)',
      build: () {
        when(() => repo.sendPhoneOtp(cancel: any(named: 'cancel')))
            .thenAnswer((_) async => const Duration(seconds: 300));
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const PhoneSendOtpRequested()),
      expect: () => [
        isA<VerificationState>().having(
          (s) => s.phone.status,
          'phone.status',
          ChannelStatus.sending,
        ),
        isA<VerificationState>()
            .having(
              (s) => s.phone.status,
              'phone.status',
              ChannelStatus.awaitingCode,
            )
            .having((s) => s.phone.expiresAt, 'phone.expiresAt', isNotNull),
      ],
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify happy path → verified, repo called with code only',
      build: () {
        when(() => repo.verifyPhoneOtp(any(), cancel: any(named: 'cancel')))
            .thenAnswer((_) async => _session());
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const PhoneVerifyOtpRequested('123456')),
      verify: (bloc) {
        expect(bloc.state.phone.status, ChannelStatus.verified);
        verify(() => repo.verifyPhoneOtp(
              '123456',
              cancel: any(named: 'cancel'),
            )).called(1);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify with no prior send still reaches the repo (no client guard)',
      // audit-003 M-03: the phone never lives client-side, so there is
      // no "did a send happen" gate — structurally identical to email.
      build: () {
        when(() => repo.verifyPhoneOtp(any(), cancel: any(named: 'cancel')))
            .thenAnswer((_) async => _session());
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) => bloc.add(const PhoneVerifyOtpRequested('123456')),
      verify: (bloc) {
        verify(() => repo.verifyPhoneOtp(
              '123456',
              cancel: any(named: 'cancel'),
            )).called(1);
      },
    );
  });

  group('error clearing', () {
    blocTest<VerificationBloc, VerificationState>(
      'VerificationErrorCleared wipes only the target channel',
      build: () => VerificationBloc(verificationRepository: repo),
      seed: () => const VerificationState(
        email: ChannelState(errorCode: VerificationErrorCode.otpInvalid),
        phone: ChannelState(errorCode: VerificationErrorCode.sendOtpFailed),
      ),
      act: (bloc) =>
          bloc.add(const VerificationErrorCleared(VerificationChannel.email)),
      verify: (bloc) {
        expect(bloc.state.email.errorCode, isNull);
        expect(bloc.state.phone.errorCode, VerificationErrorCode.sendOtpFailed);
      },
    );
  });

  group('cancellation (audit-002 H-02)', () {
    test('close() cancels in-flight email + phone tokens', () async {
      // Capture the CancelTokens the bloc hands to the repo so we can
      // assert they were cancelled. Use a Completer to keep the call
      // in flight until we close the bloc.
      final emailCompleter = Completer<Duration>();
      final phoneCompleter = Completer<Duration>();
      CancelToken? capturedEmail;
      CancelToken? capturedPhone;

      when(() => repo.sendEmailOtp(cancel: any(named: 'cancel')))
          .thenAnswer((inv) {
        capturedEmail = inv.namedArguments[#cancel] as CancelToken?;
        return emailCompleter.future;
      });
      when(() => repo.sendPhoneOtp(cancel: any(named: 'cancel')))
          .thenAnswer((inv) {
        capturedPhone = inv.namedArguments[#cancel] as CancelToken?;
        return phoneCompleter.future;
      });

      final bloc = VerificationBloc(verificationRepository: repo);
      bloc.add(const EmailSendOtpRequested());
      bloc.add(const PhoneSendOtpRequested());
      await Future<void>.delayed(Duration.zero);

      // The bloc handed live tokens to both channels.
      expect(capturedEmail, isNotNull);
      expect(capturedPhone, isNotNull);
      expect(capturedEmail!.isCancelled, isFalse);
      expect(capturedPhone!.isCancelled, isFalse);

      // Closing the bloc cancels both. (Unblock the completers afterwards
      // so the test cleans up.)
      await bloc.close();
      expect(capturedEmail!.isCancelled, isTrue);
      expect(capturedPhone!.isCancelled, isTrue);

      emailCompleter.complete(const Duration(seconds: 1));
      phoneCompleter.complete(const Duration(seconds: 1));
    });

    blocTest<VerificationBloc, VerificationState>(
      'CancelledException in send is silently absorbed (no emit)',
      build: () {
        when(() => repo.sendEmailOtp(cancel: any(named: 'cancel')))
            .thenThrow(const CancelledException());
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const EmailSendOtpRequested());
        await Future<void>.delayed(Duration.zero);
      },
      // Sending starts but no error/awaitingCode follow-up emit happens
      // because the cancel arm bails before the second emit.
      expect: () => [
        isA<VerificationState>().having(
          (s) => s.email.status,
          'email.status',
          ChannelStatus.sending,
        ),
      ],
    );
  });
}
