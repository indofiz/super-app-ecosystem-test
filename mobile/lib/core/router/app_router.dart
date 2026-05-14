import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/auth_repository.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/verification/presentation/bloc/verification_bloc.dart';
import '../../features/verification/presentation/screens/email_otp_screen.dart';
import '../../features/verification/presentation/screens/phone_otp_screen.dart';
import '../../features/verification/presentation/screens/verification_screen.dart';

class AppRouter {
  AppRouter({required this.authBloc}) {
    _refresh = _AuthBlocListenable(authBloc);
    config = GoRouter(
      initialLocation: '/splash',
      refreshListenable: _refresh,
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
              authRepository: ctx.read<AuthRepository>(),
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

  final AuthBloc authBloc;
  late final _AuthBlocListenable _refresh;
  late final GoRouter config;

  String? _redirect(_, GoRouterState state) {
    final status = authBloc.state.status;
    final loc = state.matchedLocation;

    if (status == AuthStatus.unknown) {
      return loc == '/splash' ? null : '/splash';
    }
    if (status == AuthStatus.authenticated) {
      if (loc == '/splash' || loc == '/login') return '/home';
      return null;
    }
    // unauthenticated / authenticating
    if (loc == '/splash' || loc == '/home') return '/login';
    return null;
  }

  void dispose() => _refresh.dispose();
}

class _AuthBlocListenable extends ChangeNotifier {
  _AuthBlocListenable(AuthBloc bloc) {
    _sub = bloc.stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
