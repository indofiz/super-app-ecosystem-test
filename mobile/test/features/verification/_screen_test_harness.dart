import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:smart_app_test/features/verification/presentation/bloc/verification_bloc.dart';
import 'package:smart_app_test/l10n/app_localizations.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class MockVerificationBloc
    extends MockBloc<VerificationEvent, VerificationState>
    implements VerificationBloc {}

/// Build an [AuthSession] in whatever verification state the test needs.
/// All optional fields default to "unverified" with a stock email.
AuthSession session({
  bool emailVerified = false,
  bool phoneNumberVerified = false,
  String? email = 'andi@example.test',
  String? phoneNumber,
}) =>
    AuthSession(
      accessToken: 'jwt',
      sessionId: 'sid-1',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      email: email,
      emailVerified: emailVerified,
      phoneNumber: phoneNumber,
      phoneNumberVerified: phoneNumberVerified,
    );

/// Push [screen] onto a route stack inside a MaterialApp wired with both
/// the auth and verification blocs. The route push happens after the
/// first frame so `pop` lands on a "HOME_MARKER" page (which the test
/// can `find.text(...)` to assert success → pop happened).
Future<void> pumpScreen(
  WidgetTester tester, {
  required Widget screen,
  required VerificationBloc verificationBloc,
  required AuthBloc authBloc,
}) async {
  await tester.pumpWidget(
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: authBloc),
        BlocProvider<VerificationBloc>.value(value: verificationBloc),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('id'),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(builder: (_) => screen),
                ),
                child: const Text('HOME_MARKER'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // Tap to push the screen under test. We pump a fixed 500 ms rather
  // than pumpAndSettle: some screens show a CircularProgressIndicator
  // (verifying state) which never "settles", so pumpAndSettle would
  // time out. 500 ms is enough for MaterialPageRoute's default
  // transition (~300 ms) plus the addPostFrameCallback fires.
  await tester.tap(find.text('HOME_MARKER'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}
