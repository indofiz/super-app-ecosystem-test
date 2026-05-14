import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/domain/auth_repository.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

AuthSession _session() => AuthSession(
      accessToken: 'jwt',
      sessionId: 'sid-1',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      emailVerified: false,
      phoneNumberVerified: false,
    );

void main() {
  late _MockAuthRepository repo;

  setUp(() {
    repo = _MockAuthRepository();
  });

  group('email channel', () {
    blocTest<VerificationBloc, VerificationState>(
      'sending → awaitingCode on successful send',
      build: () {
        when(repo.sendEmailOtp).thenAnswer(
          (_) async => const Duration(seconds: 300),
        );
        return VerificationBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailSendOtpRequested()),
      // Two transitions: sending, then awaitingCode.
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
      'send failure → idle with error',
      build: () {
        when(repo.sendEmailOtp).thenThrow(AuthFailure('SMTP down'));
        return VerificationBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailSendOtpRequested()),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.errorMessage, 'SMTP down');
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'verify happy path → verified',
      build: () {
        when(() => repo.verifyEmailOtp(any())).thenAnswer((_) async => _session());
        return VerificationBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('123456')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.verified);
        expect(bloc.state.email.errorMessage, isNull);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'OtpInvalidFailure with attemptsLeft>0 → awaitingCode + message',
      build: () {
        when(() => repo.verifyEmailOtp(any()))
            .thenThrow(OtpInvalidFailure(attemptsLeft: 3));
        return VerificationBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.awaitingCode);
        expect(bloc.state.email.errorMessage, contains('Sisa percobaan: 3'));
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'OtpInvalidFailure with attemptsLeft=0 → idle (forces resend)',
      build: () {
        when(() => repo.verifyEmailOtp(any()))
            .thenThrow(OtpInvalidFailure(attemptsLeft: 0));
        return VerificationBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.errorMessage, isNotNull);
      },
    );

    blocTest<VerificationBloc, VerificationState>(
      'OtpExpiredFailure → idle, expiresAt cleared',
      build: () {
        when(() => repo.verifyEmailOtp(any())).thenThrow(OtpExpiredFailure());
        return VerificationBloc(authRepository: repo);
      },
      seed: () => const VerificationState(
        email: ChannelState(
          status: ChannelStatus.awaitingCode,
          // any non-null DateTime; the bloc should clear it
        ),
      ),
      act: (bloc) => bloc.add(const EmailVerifyOtpRequested('000000')),
      verify: (bloc) {
        expect(bloc.state.email.status, ChannelStatus.idle);
        expect(bloc.state.email.expiresAt, isNull);
        expect(bloc.state.email.errorMessage, contains('kedaluwarsa'));
      },
    );
  });

  group('phone channel', () {
    blocTest<VerificationBloc, VerificationState>(
      'send: caches phoneNumber + transitions to awaitingCode',
      build: () {
        when(() => repo.sendPhoneOtp(any()))
            .thenAnswer((_) async => const Duration(seconds: 300));
        return VerificationBloc(authRepository: repo);
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
        return VerificationBloc(authRepository: repo);
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
      'verify without a prior send → error, no repo call',
      build: () => VerificationBloc(authRepository: repo),
      act: (bloc) => bloc.add(const PhoneVerifyOtpRequested('123456')),
      verify: (bloc) {
        expect(bloc.state.phone.errorMessage, isNotNull);
        verifyNever(() => repo.verifyPhoneOtp(any(), any()));
      },
    );
  });

  group('error clearing', () {
    blocTest<VerificationBloc, VerificationState>(
      'VerificationErrorCleared wipes only the target channel',
      build: () => VerificationBloc(authRepository: repo),
      seed: () => const VerificationState(
        email: ChannelState(errorMessage: 'old email error'),
        phone: ChannelState(errorMessage: 'old phone error'),
      ),
      act: (bloc) =>
          bloc.add(const VerificationErrorCleared(VerificationChannel.email)),
      verify: (bloc) {
        expect(bloc.state.email.errorMessage, isNull);
        expect(bloc.state.phone.errorMessage, 'old phone error');
      },
    );
  });
}
