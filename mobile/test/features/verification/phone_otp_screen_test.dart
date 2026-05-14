import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/screens/phone_otp_screen.dart';

import '_screen_test_harness.dart';

void main() {
  late MockVerificationBloc vBloc;
  late MockAuthBloc aBloc;

  setUp(() {
    vBloc = MockVerificationBloc();
    aBloc = MockAuthBloc();
    registerFallbackValue(const PhoneSendOtpRequested(''));
    registerFallbackValue(const PhoneVerifyOtpRequested(''));
  });

  Future<void> mount(
    WidgetTester tester, {
    VerificationState vState = const VerificationState(),
    AuthState? aState,
    Stream<VerificationState>? vStream,
  }) async {
    whenListen(
      vBloc,
      vStream ?? const Stream<VerificationState>.empty(),
      initialState: vState,
    );
    whenListen(
      aBloc,
      const Stream<AuthState>.empty(),
      initialState: aState ?? AuthState.authenticated(session()),
    );
    await pumpScreen(
      tester,
      screen: const PhoneOtpScreen(),
      verificationBloc: vBloc,
      authBloc: aBloc,
    );
  }

  group('phone-input step (idle)', () {
    testWidgets('renders the phone form by default, not the OTP input',
        (tester) async {
      await mount(tester);
      // Phone-input step has a labelled "Nomor WhatsApp" field, NOT
      // a 6-digit OTP cell.
      expect(find.text('Nomor WhatsApp'), findsOneWidget);
      expect(find.text('Kirim Kode'), findsOneWidget);
      // No OtpInput cells visible yet.
      expect(find.text('Verifikasi'), findsNothing);
    });

    testWidgets(
      'prefills phone from existing session.phoneNumber (stripped to digits)',
      (tester) async {
        // Controller holds digits only; `+62` is fixed prefix chrome.
        await mount(
          tester,
          aState: AuthState.authenticated(
            session(phoneNumber: '+6281234567890'),
          ),
        );
        expect(find.text('81234567890'), findsOneWidget);
      },
    );

    testWidgets('form rejects too-short input (less than 8 digits)',
        (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(TextField), '1234567');
      await tester.tap(find.text('Kirim Kode'));
      await tester.pump();
      expect(
        find.text('Masukkan 8–12 digit setelah +62'),
        findsOneWidget,
      );
      // Form failure → no event dispatched.
      verifyNever(() => vBloc.add(any(that: isA<PhoneSendOtpRequested>())));
    });

    testWidgets(
      'valid digit entry → Kirim Kode dispatches with +62 reattached',
      (tester) async {
        await mount(tester);
        // User types the local part; `+62` is structural chrome and is
        // re-attached at dispatch time.
        await tester.enterText(find.byType(TextField), '81234567890');
        await tester.tap(find.text('Kirim Kode'));
        await tester.pump();
        verify(
          () => vBloc.add(const PhoneSendOtpRequested('+6281234567890')),
        ).called(1);
      },
    );
  });

  group('code-input step (awaitingCode)', () {
    Future<void> mountCodeStep(
      WidgetTester tester, {
      String phone = '+6281234567890',
      String? errorMessage,
      ChannelStatus status = ChannelStatus.awaitingCode,
    }) =>
        mount(
          tester,
          vState: VerificationState(
            phone: ChannelState(
              status: status,
              phoneNumber: phone,
              expiresAt: DateTime.now().add(const Duration(minutes: 5)),
              errorMessage: errorMessage,
            ),
          ),
        );

    testWidgets('renders OTP input + shows the issued phone number',
        (tester) async {
      await mountCodeStep(tester);
      expect(find.text('+6281234567890'), findsOneWidget);
      expect(find.text('Verifikasi'), findsOneWidget);
      // We're on the code step → the "Nomor WhatsApp" labelled field is gone.
      expect(find.text('Nomor WhatsApp'), findsNothing);
    });

    testWidgets('Verifikasi button is disabled until 6 digits entered',
        (tester) async {
      await mountCodeStep(tester);
      final btn = find.widgetWithText(FilledButton, 'Verifikasi');
      expect(tester.widget<FilledButton>(btn).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '12345');
      await tester.pump();
      expect(tester.widget<FilledButton>(btn).onPressed, isNull);
    });

    testWidgets(
      'entering 6 digits dispatches PhoneVerifyOtpRequested with the code',
      (tester) async {
        await mountCodeStep(tester);
        await tester.enterText(find.byType(TextField), '987654');
        await tester.pump();
        verify(
          () => vBloc.add(const PhoneVerifyOtpRequested('987654')),
        ).called(1);
      },
    );

    testWidgets('error message is shown when state carries one',
        (tester) async {
      await mountCodeStep(
        tester,
        errorMessage: 'Kode salah. Sisa percobaan: 2.',
      );
      expect(find.text('Kode salah. Sisa percobaan: 2.'), findsOneWidget);
    });

    testWidgets('"Ubah nomor" pops the screen back to the previous route',
        (tester) async {
      await mountCodeStep(tester);
      expect(find.byType(PhoneOtpScreen), findsOneWidget);
      await tester.tap(find.text('Ubah nomor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PhoneOtpScreen), findsNothing);
      expect(find.text('HOME_MARKER'), findsOneWidget);
    });
  });

  testWidgets(
    'transition to ChannelStatus.verified pops back + shows snackbar',
    (tester) async {
      const verified = VerificationState(
        phone: ChannelState(
          status: ChannelStatus.verified,
          phoneNumber: '+6281234567890',
        ),
      );
      await mount(
        tester,
        vState: const VerificationState(
          phone: ChannelState(
            status: ChannelStatus.awaitingCode,
            phoneNumber: '+6281234567890',
          ),
        ),
        vStream: Stream<VerificationState>.value(verified),
      );
      // Let the snackbar animation flush and the route pop complete.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PhoneOtpScreen), findsNothing);
      expect(find.text('HOME_MARKER'), findsOneWidget);
    },
  );
}
