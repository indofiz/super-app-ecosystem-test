import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/verification/domain/verification_failure.dart';
import 'package:smart_app_test/features/verification/domain/verification_repository.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';

class _MockVerificationRepository extends Mock
    implements VerificationRepository {}

AuthSession _session() => AuthSession(
      accessToken: 'jwt',
      sessionId: 'sid-1',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      emailVerified: false,
      phoneNumberVerified: false,
    );

void main() {
  late _MockVerificationRepository repo;

  setUp(() {
    repo = _MockVerificationRepository();
  });

  group('email channel', () {
    blocTest<VerificationBloc, VerificationState>(
      'sending → awaitingCode on successful send',
      build: () {
        when(repo.sendEmailOtp).thenAnswer(
          (_) async => const Duration(seconds: 300),
        );
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
        when(repo.sendEmailOtp).thenThrow(
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
        when(() => repo.verifyEmailOtp(any())).thenAnswer((_) async => _session());
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
        when(() => repo.verifyEmailOtp(any())).thenThrow(
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
        when(() => repo.verifyEmailOtp(any())).thenThrow(
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
        when(() => repo.verifyEmailOtp(any())).thenThrow(
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

  group('phone channel', () {
    blocTest<VerificationBloc, VerificationState>(
      'send: caches phoneNumber + transitions to awaitingCode',
      build: () {
        when(() => repo.sendPhoneOtp(any()))
            .thenAnswer((_) async => const Duration(seconds: 300));
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) =>
          bloc.add(const PhoneSendOtpRequested('+6281234567890')),
      verify: (bloc) {
        expect(bloc.state.phone.status, ChannelStatus.awaitingCode);
        expect(bloc.state.phone.phoneNumber, '+6281234567890');
        expect(bloc.state.phone.expiresAt, isNotNull);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify uses the cached phoneNumber from the previous send',
      build: () {
        when(() => repo.sendPhoneOtp(any()))
            .thenAnswer((_) async => const Duration(seconds: 300));
        when(() => repo.verifyPhoneOtp(any(), any()))
            .thenAnswer((_) async => _session());
        return VerificationBloc(verificationRepository: repo);
      },
      act: (bloc) async {
        bloc.add(const PhoneSendOtpRequested('+6281234567890'));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const PhoneVerifyOtpRequested('123456'));
      },
      verify: (bloc) {
        expect(bloc.state.phone.status, ChannelStatus.verified);
        verify(() => repo.verifyPhoneOtp('+6281234567890', '123456')).called(1);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify without a prior send → phoneNotEntered code, no repo call',
      build: () => VerificationBloc(verificationRepository: repo),
      act: (bloc) => bloc.add(const PhoneVerifyOtpRequested('123456')),
      verify: (bloc) {
        expect(
          bloc.state.phone.errorCode,
          VerificationErrorCode.phoneNotEntered,
        );
        verifyNever(() => repo.verifyPhoneOtp(any(), any()));
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
}
