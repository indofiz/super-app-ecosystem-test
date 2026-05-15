import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/core/router/app_router.dart';
import 'package:smart_app_test/core/router/auth_status_listenable.dart';
import 'package:smart_app_test/features/auth/domain/auth_repository.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';

/// Fake listenable so the router can be tested without an AuthBloc.
class _FakeAuthStatus extends AuthStatusListenable {
  _FakeAuthStatus(this._status);
  AuthStatus _status;
  @override
  AuthStatus get status => _status;
  void set(AuthStatus s) {
    _status = s;
    notifyListeners();
  }
}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

String _currentLocation(AppRouter router) =>
    router.config.routerDelegate.currentConfiguration.uri.toString();

/// Pumps just enough frames for go_router to apply its initial redirect.
/// We deliberately avoid [pumpAndSettle] — splash and login render
/// indeterminate progress indicators that never settle.
Future<void> _pump(WidgetTester tester, AppRouter router) async {
  final bloc = _MockAuthBloc();
  whenListen(
    bloc,
    const Stream<AuthState>.empty(),
    initialState: const AuthState.unknown(),
  );

  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<AuthRepository>.value(value: _MockAuthRepository()),
      ],
      child: BlocProvider<AuthBloc>.value(
        value: bloc,
        child: MaterialApp.router(routerConfig: router.config),
      ),
    ),
  );
  // Two pumps: first frame builds the router, second lets the redirect
  // apply and the target screen build.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('AppRouter redirect', () {
    testWidgets('AuthStatus.unknown lands on /splash', (tester) async {
      final router = AppRouter(status: _FakeAuthStatus(AuthStatus.unknown));
      await _pump(tester, router);
      expect(_currentLocation(router), '/splash');
    });

    testWidgets('AuthStatus.unauthenticated lands on /login', (tester) async {
      final router =
          AppRouter(status: _FakeAuthStatus(AuthStatus.unauthenticated));
      await _pump(tester, router);
      expect(_currentLocation(router), '/login');
    });

    testWidgets('AuthStatus.authenticated lands on /home', (tester) async {
      final router =
          AppRouter(status: _FakeAuthStatus(AuthStatus.authenticated));
      await _pump(tester, router);
      expect(_currentLocation(router), '/home');
    });

    testWidgets(
        'transitioning unauthenticated → authenticated redirects /login → /home',
        (tester) async {
      final status = _FakeAuthStatus(AuthStatus.unauthenticated);
      final router = AppRouter(status: status);
      await _pump(tester, router);
      expect(_currentLocation(router), '/login');

      status.set(AuthStatus.authenticated);
      await tester.pump();
      await tester.pump();

      expect(_currentLocation(router), '/home');
    });
  });
}
