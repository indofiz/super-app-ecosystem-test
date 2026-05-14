import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:smart_app_test/features/home/presentation/widgets/verification_banner.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

AuthSession _session({
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

/// Pumps the banner inside a minimal go_router so `context.push('/verify')`
/// resolves. The fake `/verify` page just renders a marker text the test
/// can `find.text(...)` after navigation to confirm it landed.
Future<void> _pumpBanner(
  WidgetTester tester, {
  required AuthState authState,
}) async {
  final bloc = _MockAuthBloc();
  whenListen(
    bloc,
    const Stream<AuthState>.empty(),
    initialState: authState,
  );

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Column(
            children: const [VerificationBanner(), Expanded(child: SizedBox())],
          ),
        ),
      ),
      GoRoute(
        path: '/verify',
        builder: (_, __) => const Scaffold(
          body: Center(child: Text('VERIFY_PAGE_MARKER')),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    BlocProvider<AuthBloc>.value(
      value: bloc,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

void main() {
  group('VerificationBanner', () {
    testWidgets('renders nothing when both flags are true', (tester) async {
      await _pumpBanner(
        tester,
        authState: AuthState.authenticated(
          _session(emailVerified: true, phoneNumberVerified: true),
        ),
      );
      // The banner returns SizedBox.shrink → no MaterialBanner-style row
      // and no "Verifikasi" CTA.
      expect(find.text('Verifikasi'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('renders nothing when there is no session', (tester) async {
      await _pumpBanner(tester, authState: const AuthState.unauthenticated());
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('email-only missing → singular message mentions "email"',
        (tester) async {
      await _pumpBanner(
        tester,
        authState: AuthState.authenticated(
          _session(emailVerified: false, phoneNumberVerified: true),
        ),
      );
      expect(
        find.text('Verifikasi email Anda untuk membuka semua fitur.'),
        findsOneWidget,
      );
      // The "WhatsApp" wording must NOT appear in this state.
      expect(find.textContaining('WhatsApp'), findsNothing);
    });

    testWidgets('phone-only missing → singular message mentions "WhatsApp"',
        (tester) async {
      await _pumpBanner(
        tester,
        authState: AuthState.authenticated(
          _session(emailVerified: true, phoneNumberVerified: false),
        ),
      );
      expect(
        find.text(
          'Verifikasi nomor WhatsApp Anda untuk membuka semua fitur.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('both missing → generic "akun belum diverifikasi" message',
        (tester) async {
      await _pumpBanner(
        tester,
        authState: AuthState.authenticated(_session()),
      );
      expect(find.text('Akun Anda belum diverifikasi.'), findsOneWidget);
      expect(find.text('Verifikasi'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('tap navigates to /verify', (tester) async {
      await _pumpBanner(
        tester,
        authState: AuthState.authenticated(_session()),
      );
      // Confirm we're on home first.
      expect(find.text('VERIFY_PAGE_MARKER'), findsNothing);

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(find.text('VERIFY_PAGE_MARKER'), findsOneWidget);
      // Banner is gone because we're on /verify now (a different route).
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });
  });
}
