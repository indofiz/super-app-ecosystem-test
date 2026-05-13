import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/home/presentation/home_screen.dart';

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
