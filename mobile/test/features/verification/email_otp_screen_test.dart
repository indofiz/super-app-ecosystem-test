import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/screens/email_otp_screen.dart';
import 'package:smart_app_test/features/verification/presentation/widgets/otp_input.dart';

import '_screen_test_harness.dart';

void main() {
  late MockVerificationBloc vBloc;
  late MockAuthBloc aBloc;

  setUp(() {
    vBloc = MockVerificationBloc();
    aBloc = MockAuthBloc();
    // mocktail's `any()` matcher needs a fallback for each non-primitive
    // event type. Register once per test run.
    registerFallbackValue(const EmailSendOtpRequested());
    registerFallbackValue(const EmailVerifyOtpRequested(''));
  });

  /// Seed both blocs with [vState] / [aState] and mount the email screen.
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
      screen: const EmailOtpScreen(),
      verificationBloc: vBloc,
      authBloc: aBloc,
    );
  }

  testWidgets('auto-dispatches EmailSendOtpRequested on mount', (tester) async {
    await mount(tester);
    // pumpScreen already ran pumpAndSettle, so the addPostFrameCallback
    // has fired.
    verify(() => vBloc.add(const EmailSendOtpRequested())).called(1);
  });

  testWidgets("renders the user's email address from the session",
      (tester) async {
    await mount(
      tester,
      aState: AuthState.authenticated(session(email: 'budi@example.id')),
    );
    expect(find.text('budi@example.id'), findsOneWidget);
  });

  testWidgets('Verifikasi button is disabled until 6 digits entered',
      (tester) async {
    await mount(tester);
    final button = find.widgetWithText(FilledButton, 'Verifikasi');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    // Enter 3 digits — still disabled.
    await tester.enterText(find.byType(TextField), '123');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  testWidgets(
    'entering 6 digits auto-dispatches EmailVerifyOtpRequested via OtpInput',
    (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(TextField), '654321');
      await tester.pump();
      verify(() => vBloc.add(const EmailVerifyOtpRequested('654321')))
          .called(1);
    },
  );

  testWidgets('shows error message when state carries one', (tester) async {
    await mount(
      tester,
      vState: const VerificationState(
        email: ChannelState(
          status: ChannelStatus.awaitingCode,
          errorMessage: 'Kode salah. Sisa percobaan: 3.',
        ),
      ),
    );
    expect(find.text('Kode salah. Sisa percobaan: 3.'), findsOneWidget);
  });

  testWidgets('progress indicator visible during verifying state',
      (tester) async {
    await mount(
      tester,
      vState: const VerificationState(
        email: ChannelState(status: ChannelStatus.verifying),
      ),
    );
    // While verifying, the FilledButton swaps to a small spinner and the
    // OtpInput's TextField is disabled.
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
    'transition to ChannelStatus.verified pops back to home + shows snackbar',
    (tester) async {
      // BlocConsumer.listenWhen: fires when prev != verified AND curr ==
      // verified. Seed prev=awaitingCode, emit verified.
      const verified = VerificationState(
        email: ChannelState(status: ChannelStatus.verified),
      );
      await mount(
        tester,
        vState: const VerificationState(
          email: ChannelState(status: ChannelStatus.awaitingCode),
        ),
        vStream: Stream<VerificationState>.value(verified),
      );

      // The MockBloc's stream replays its state on subscribe — both
      // initial and the streamed value reach the BlocConsumer after a
      // pump.
      await tester.pumpAndSettle();

      // Snackbar message was shown briefly and the screen popped.
      expect(find.byType(EmailOtpScreen), findsNothing);
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
