import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/screens/phone_otp_screen.dart';
import 'package:smart_app_test/features/verification/presentation/widgets/otp_input.dart';

import '_screen_test_harness.dart';

/// audit-003 M-03: the phone screen is structurally identical to the
/// email screen — no in-app phone-entry step. The BFF reads the citizen's
/// number from their Keycloak profile; the UI only shows it (from the
/// auth session) and collects the 6-digit code.
void main() {
  late MockVerificationBloc vBloc;
  late MockAuthBloc aBloc;

  setUp(() {
    vBloc = MockVerificationBloc();
    aBloc = MockAuthBloc();
    registerFallbackValue(const PhoneSendOtpRequested());
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
      initialState: aState ??
          AuthState.authenticated(session(phoneNumber: '+6281234567890')),
    );
    await pumpScreen(
      tester,
      screen: const PhoneOtpScreen(),
      verificationBloc: vBloc,
      authBloc: aBloc,
    );
  }

  testWidgets('auto-dispatches PhoneSendOtpRequested on mount when idle',
      (tester) async {
    await mount(tester);
    verify(() => vBloc.add(const PhoneSendOtpRequested())).called(1);
  });

  testWidgets('does NOT auto-send when a code is already awaiting',
      (tester) async {
    // M-02: re-entering /verify/phone against a live code must not pump
    // a fresh send-OTP at the user.
    await mount(
      tester,
      vState: const VerificationState(
        phone: ChannelState(status: ChannelStatus.awaitingCode),
      ),
    );
    verifyNever(() => vBloc.add(const PhoneSendOtpRequested()));
  });

  testWidgets("renders the user's phone number from the session",
      (tester) async {
    await mount(
      tester,
      aState: AuthState.authenticated(session(phoneNumber: '+6285711112222')),
    );
    expect(find.text('+6285711112222'), findsOneWidget);
    // No phone-entry field — the number is not collected in-app.
    expect(find.text('Nomor WhatsApp'), findsNothing);
  });

  testWidgets('Verifikasi button is disabled until 6 digits entered',
      (tester) async {
    await mount(tester);
    final button = find.widgetWithText(FilledButton, 'Verifikasi');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), '123');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets(
    'entering 6 digits auto-dispatches PhoneVerifyOtpRequested via OtpInput',
    (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(TextField), '987654');
      await tester.pump();
      verify(() => vBloc.add(const PhoneVerifyOtpRequested('987654')))
          .called(1);
    },
  );

  testWidgets('shows localized error message when state carries one',
      (tester) async {
    await mount(
      tester,
      vState: const VerificationState(
        phone: ChannelState(
          status: ChannelStatus.awaitingCode,
          errorCode: VerificationErrorCode.otpInvalid,
          attemptsLeft: 2,
        ),
      ),
    );
    expect(find.text('Kode salah. Sisa percobaan: 2.'), findsOneWidget);
  });

  testWidgets('progress indicator visible during verifying state',
      (tester) async {
    await mount(
      tester,
      vState: const VerificationState(
        phone: ChannelState(status: ChannelStatus.verifying),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).enabled,
      isFalse,
    );
  });

  testWidgets(
    'transition to ChannelStatus.verified pops back + shows snackbar',
    (tester) async {
      const verified = VerificationState(
        phone: ChannelState(status: ChannelStatus.verified),
      );
      await mount(
        tester,
        vState: const VerificationState(
          phone: ChannelState(status: ChannelStatus.awaitingCode),
        ),
        vStream: Stream<VerificationState>.value(verified),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PhoneOtpScreen), findsNothing);
      expect(find.text('HOME_MARKER'), findsOneWidget);
    },
  );

  testWidgets('OtpInput renders exactly one underlying TextField + 6 cells',
      (tester) async {
    await mount(tester);
    expect(find.byType(OtpInput), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
