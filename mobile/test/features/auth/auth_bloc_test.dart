import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/domain/auth_repository.dart';
import 'package:smart_app_test/features/auth/domain/auth_session.dart';
import 'package:smart_app_test/features/auth/presentation/bloc/auth_bloc.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late _MockAuthRepository repo;
  late StreamController<AuthSession?> sessionController;

  AuthSession validSession() => AuthSession(
        accessToken: 'jwt',
        sessionId: 'sid-1',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );

  AuthSession expiredSession() => AuthSession(
        accessToken: 'jwt-old',
        sessionId: 'sid-1',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

  setUp(() {
    repo = _MockAuthRepository();
    sessionController = StreamController<AuthSession?>.broadcast();
    when(() => repo.sessionChanges).thenAnswer((_) => sessionController.stream);
  });

  tearDown(() async {
    await sessionController.close();
  });

  group('AuthStarted', () {
    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when no session is stored',
      build: () {
        when(repo.restoreSession).thenAnswer((_) async => null);
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthStarted()),
      expect: () => [const AuthState.unauthenticated()],
    );

    blocTest<AuthBloc, AuthState>(
      'emits authenticated when a valid session is restored',
      build: () {
        final s = validSession();
        when(repo.restoreSession).thenAnswer((_) async => s);
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthStarted()),
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
        expect(bloc.state.session, isNotNull);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when the restored session is expired',
      build: () {
        when(repo.restoreSession).thenAnswer((_) async => expiredSession());
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthStarted()),
      expect: () => [const AuthState.unauthenticated()],
    );
  });

  group('AuthLoginRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticating then authenticated on success',
      build: () {
        when(repo.login).thenAnswer((_) async => validSession());
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthLoginRequested()),
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits authenticating then unauthenticated with error on AuthFailure',
      build: () {
        when(repo.login).thenThrow(AuthFailure('nope'));
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthLoginRequested()),
      expect: () => [
        const AuthState.authenticating(),
        const AuthState.unauthenticated(errorMessage: 'nope'),
      ],
    );
  });

  group('AuthRefreshRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticated with new session on success',
      build: () {
        when(repo.refresh).thenAnswer((_) async => validSession());
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthRefreshRequested()),
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated with message when refresh fails',
      build: () {
        when(repo.refresh).thenThrow(AuthFailure('refresh dead'));
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthRefreshRequested()),
      expect: () => [
        const AuthState.unauthenticated(errorMessage: 'refresh dead'),
      ],
    );
  });

  group('AuthLogoutRequested', () {
    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated after logout',
      build: () {
        when(() => repo.logout()).thenAnswer((_) async {});
        return AuthBloc(authRepository: repo);
      },
      act: (bloc) => bloc.add(const AuthLogoutRequested()),
      expect: () => [const AuthState.unauthenticated()],
    );
  });

  group('session stream', () {
    blocTest<AuthBloc, AuthState>(
      'emits authenticated when repo broadcasts a new session',
      build: () => AuthBloc(authRepository: repo),
      act: (_) async {
        sessionController.add(validSession());
        await Future<void>.delayed(Duration.zero);
      },
      verify: (bloc) {
        expect(bloc.state.status, AuthStatus.authenticated);
      },
    );

    blocTest<AuthBloc, AuthState>(
      'emits unauthenticated when repo broadcasts null',
      build: () => AuthBloc(authRepository: repo),
      act: (_) async {
        sessionController.add(null);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [const AuthState.unauthenticated()],
    );
  });
}
