import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/auth_status.dart';
import '../../features/verification/domain/verification_repository.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/verification/presentation/bloc/verification_bloc.dart';
import '../../features/verification/presentation/screens/email_otp_screen.dart';
import '../../features/verification/presentation/screens/phone_otp_screen.dart';
import '../../features/verification/presentation/screens/verification_screen.dart';
import 'auth_status_listenable.dart';

/// Top-level router. Depends only on the framework-neutral
/// [AuthStatusListenable] — swapping the auth state manager (e.g. to
/// Riverpod or a pure Stream) requires no change to this file.
class AppRouter {
  AppRouter({required this.status}) {
    config = GoRouter(
      initialLocation: '/splash',
      refreshListenable: status,
      redirect: _redirect,
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
        // Verification flow is scoped to a ShellRoute so that /verify,
        // /verify/email, and /verify/phone share a single
        // VerificationBloc instance. The bloc is created the first time
        // any /verify* route is entered and disposed when the user
        // leaves the subtree. Soft gate — the redirect logic above does
        // NOT bounce unverified users here.
        ShellRoute(
          builder: (context, state, child) => BlocProvider<VerificationBloc>(
            create: (ctx) => VerificationBloc(
              verificationRepository: ctx.read<VerificationRepository>(),
            ),
            child: child,
          ),
          routes: [
            GoRoute(
              path: '/verify',
              builder: (_, __) => const VerificationScreen(),
              routes: [
                GoRoute(
                  path: 'email',
                  builder: (_, __) => const EmailOtpScreen(),
                ),
                GoRoute(
                  path: 'phone',
                  builder: (_, __) => const PhoneOtpScreen(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  final AuthStatusListenable status;
  late final GoRouter config;

  String? _redirect(_, GoRouterState state) {
    final s = status.status;
    final loc = state.matchedLocation;

    if (s == AuthStatus.unknown) {
      return loc == '/splash' ? null : '/splash';
    }
    if (s == AuthStatus.authenticated) {
      if (loc == '/splash' || loc == '/login') return '/home';
      return null;
    }
    if (s == AuthStatus.authenticating) {
      // audit-002 H-05: the cold-start silent refresh lives on /splash;
      // bouncing it to /login would flash the login screen during the
      // probe. User-initiated login happens from /login itself, which
      // also stays put. Only push /home users back to /login if a
      // refresh is in flight (anticipates logout).
      if (loc == '/home') return '/login';
      return null;
    }
    // unauthenticated
    if (loc == '/splash' || loc == '/home') return '/login';
    return null;
  }
}
